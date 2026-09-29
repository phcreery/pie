//! Image catalog behind the lighttable.
//!
//! Thumbnails are decoded with the pie engine's recommended pipeline for the
//! file type (whatever `i-*` module `pie.graphs` picks -> `downscale` ->
//! `o-qoi`) and cached as small QOI images under the user cache directory,
//! keyed by the source's path, size and mtime. Rendering happens on a worker
//! thread so browsing a directory never blocks the UI; the main thread only
//! loads the finished image and uploads it to sokol (like vkdt's `.bc1` cache,
//! minus the GPU-format step).

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const simgui = sokol.imgui;
const zigimg = @import("zigimg");
const pie = @import("pie");

const slog = std.log.scoped(.catalog);

/// longest edge of a generated thumbnail, in pixels
pub const thumb_px: u32 = 256;

/// Thumbnail cache format. QOI encodes in a fraction of PNG's time and the
/// cached pixels are uploaded as RGBA8 anyway, so the 16-bit PNG cache bought
/// nothing for the extra encode time.
const cache_module = "o-qoi";
const cache_extension = "qoi";
/// The sink's filename when the graph is built; every render re-points it.
const cache_placeholder = "thumbnail." ++ cache_extension;

/// Bumped when the cached thumbnail format/content changes, so old cache files
/// are simply missed instead of being misread.
const cache_version: u32 = 3;

/// How many finished thumbnails the main thread uploads per frame.
const uploads_per_tick: usize = 8;

/// Entry lifecycle. `pending`..`cached` are driven by the worker thread,
/// `cached`..`ready`/`failed` by the main thread; every transition is published
/// through the atomic `status`, so no lock is needed.
pub const Status = enum(u8) { pending, rendering, cached, ready, failed };

pub const Entry = struct {
    name: []u8,
    path: []u8,
    status: std.atomic.Value(Status) = .init(.pending),
    /// uploaded thumbnail, owned by the main thread
    image: sg.Image = .{},
    view: sg.View = .{},
    /// ImTextureID for `igImage`; 0 until ready
    texture: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// A cached decode pipeline: the engine's recommended graph for one input
/// family, ending in a file sink whose `filename` is re-pointed at each entry.
const Decoder = struct {
    pipeline: pie.Pipeline,
    source: pie.pipeline.ModuleHandle,
    sink: pie.pipeline.ModuleHandle,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gpu: *pie.GPU,
    dir: []u8,
    cache_dir: []u8,
    entries: []Entry = &.{},

    // Decoders are created lazily by the worker thread and only touched there
    // (or by the main thread when no worker is running). Keyed by the `i-*`
    // module that reads the file, so another decoder family needs no change
    // here. The values are heap-allocated because the map moves its storage.
    decoders: std.StringHashMapUnmanaged(*Decoder) = .empty,

    // worker bookkeeping: one thread per scan walks the entries slice once and
    // exits, so the slice must stay stable until it is joined (see `reload`).
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    const Self = @This();

    /// Heap-allocated on purpose: `Session` keeps a stable pointer and the
    /// worker thread holds one too.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: []const u8,
        cache_dir: []const u8,
        gpu: *pie.GPU,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        const abs_dir = absoluteDir(allocator, io, dir) catch |err| blk: {
            slog.warn("cannot resolve '{s}': {s}", .{ dir, @errorName(err) });
            break :blk try allocator.dupe(u8, dir);
        };
        self.* = .{
            .allocator = allocator,
            .io = io,
            .gpu = gpu,
            .dir = abs_dir,
            .cache_dir = try allocator.dupe(u8, cache_dir),
        };
        errdefer allocator.free(self.dir);
        errdefer allocator.free(self.cache_dir);

        std.Io.Dir.cwd().createDirPath(self.io, self.cache_dir) catch |err| {
            slog.warn("cannot create thumbnail cache '{s}': {s}", .{ self.cache_dir, @errorName(err) });
        };

        try self.scan();
        self.startWorker();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stopWorker();
        self.destroyThumbnails();
        self.freeEntries();
        var decoders = self.decoders.valueIterator();
        while (decoders.next()) |decoder| {
            decoder.*.pipeline.deinit();
            self.allocator.destroy(decoder.*);
        }
        self.decoders.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.allocator.free(self.cache_dir);
        self.allocator.destroy(self);
    }

    /// Rescan the directory, dropping the current thumbnails.
    pub fn reload(self: *Self) void {
        self.stopWorker();
        self.destroyThumbnails();
        self.freeEntries();
        self.entries = &.{};

        self.scan() catch |err| slog.err("rescan of '{s}' failed: {s}", .{ self.dir, @errorName(err) });
        self.startWorker();
    }

    /// Point the catalog at `dir` and rescan it. The path is resolved to an
    /// absolute one and must name a readable directory; otherwise the current
    /// directory is kept and the error is returned.
    pub fn setDir(self: *Self, dir: []const u8) !void {
        const resolved = try absoluteDir(self.allocator, self.io, dir);

        // swap only once the directory is known to be scannable
        var probe = std.Io.Dir.cwd().openDir(self.io, resolved, .{ .iterate = true }) catch |err| {
            self.allocator.free(resolved);
            return err;
        };
        probe.close(self.io);

        const old = self.dir;
        self.dir = resolved;
        self.reload();
        self.allocator.free(old);
    }

    /// Main thread: upload thumbnails the worker finished rendering. Cached
    /// images are loaded (never re-rendered), so this is cheap.
    pub fn tick(self: *Self) void {
        // If the worker could not be spawned, fall back to rendering one
        // pending thumbnail per frame on this thread.
        if (self.thread == null) self.renderPendingOnMainThread();

        var uploaded: usize = 0;
        for (self.entries) |*entry| {
            if (entry.status.load(.acquire) != Status.cached) continue;
            self.uploadEntry(entry) catch |err| {
                slog.warn("thumbnail for '{s}' failed: {s}", .{ entry.path, @errorName(err) });
                entry.status.store(Status.failed, .release);
                continue;
            };
            entry.status.store(Status.ready, .release);
            uploaded += 1;
            if (uploaded >= uploads_per_tick) break;
        }
    }

    /// Is the thumbnail for `index` ready to be drawn?
    pub fn textureOf(self: *const Self, index: usize) u64 {
        if (index >= self.entries.len) return 0;
        return self.entries[index].texture;
    }

    pub fn thumbSize(self: *const Self, index: usize) [2]u32 {
        if (index >= self.entries.len) return .{ 0, 0 };
        return .{ self.entries[index].width, self.entries[index].height };
    }

    pub fn entryState(self: *const Self, index: usize) struct { failed: bool, ready: bool } {
        if (index >= self.entries.len) return .{ .failed = false, .ready = false };
        const status: Status = self.entries[index].status.load(.acquire);
        return .{
            .failed = status == .failed,
            .ready = status == .ready,
        };
    }

    // ------------------------------------------------------------------------
    // scanning
    // ------------------------------------------------------------------------

    fn scan(self: *Self) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch |err| {
            slog.err("cannot open catalog directory '{s}': {s}", .{ self.dir, @errorName(err) });
            return;
        };
        defer dir.close(self.io);

        var list: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer {
            for (list.items) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.path);
            }
            list.deinit(self.allocator);
        }

        var iterator = std.Io.Dir.iterate(dir);
        while (iterator.next(self.io) catch null) |dirent| {
            if (dirent.kind == .directory) continue;
            // The engine's registry is the single source of truth for what can
            // be decoded, so scanning can't list a file no decoder handles.
            if (pie.graphs.formatForPath(dirent.name) == null) continue;

            const path = try std.fs.path.join(self.allocator, &.{ self.dir, dirent.name });
            errdefer self.allocator.free(path);
            const name = try self.allocator.dupe(u8, dirent.name);
            try list.append(self.allocator, .{ .name = name, .path = path });
        }

        std.mem.sort(Entry, list.items, {}, lessByName);
        self.entries = try list.toOwnedSlice(self.allocator);
        slog.info("catalog: {d} images in '{s}'", .{ self.entries.len, self.dir });
    }

    fn freeEntries(self: *Self) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }

    fn destroyThumbnails(self: *Self) void {
        for (self.entries) |*entry| {
            if (entry.view.id != sg.invalid_id) sg.destroyView(entry.view);
            if (entry.image.id != sg.invalid_id) sg.destroyImage(entry.image);
            entry.view = .{};
            entry.image = .{};
            entry.texture = 0;
            entry.width = 0;
            entry.height = 0;
            entry.status.store(Status.pending, .release);
        }
    }

    // ------------------------------------------------------------------------
    // cache
    // ------------------------------------------------------------------------

    /// Cache file for `path`, keyed by everything that affects the pixels.
    /// Returns an owned absolute path.
    fn cachePath(self: *const Self, path: []const u8) ![]u8 {
        const stat = try std.Io.Dir.statFile(.cwd(), self.io, path, .{});

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path);
        var size = stat.size;
        hasher.update(std.mem.asBytes(&size));
        var mtime = stat.mtime.nanoseconds;
        hasher.update(std.mem.asBytes(&mtime));
        var thumb = thumb_px;
        hasher.update(std.mem.asBytes(&thumb));
        var version = cache_version;
        hasher.update(std.mem.asBytes(&version));

        const file = try std.fmt.allocPrint(self.allocator, "{x:0>16}.{s}", .{ hasher.final(), cache_extension });
        defer self.allocator.free(file);
        return std.fs.path.join(self.allocator, &.{ self.cache_dir, file });
    }

    /// One render pass per entry, on the worker thread.
    fn renderEntry(self: *Self, entry: *Entry) !void {
        const cache_path = try self.cachePath(entry.path);
        defer self.allocator.free(cache_path);
        // The key already contains mtime/size, so an existing file is fresh.
        std.Io.Dir.accessAbsolute(self.io, cache_path, .{}) catch {
            return self.renderToFile(entry, cache_path);
        };
    }

    fn renderToFile(self: *Self, entry: *Entry, cache_path: []const u8) !void {
        const format = pie.graphs.formatForPath(entry.path) orelse return error.UnsupportedFileType;
        const decoder = try self.ensureDecoder(format);

        // Render to a temporary file, then rename it into place so a crash or a
        // failed render can never be mistaken for a valid cache entry.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{cache_path});
        defer self.allocator.free(tmp_path);

        try decoder.pipeline.setModuleParam(decoder.source, "filename", []const u8, entry.path);
        try decoder.pipeline.setModuleParam(decoder.sink, "filename", []const u8, tmp_path);
        try decoder.pipeline.run();

        std.Io.Dir.renameAbsolute(tmp_path, cache_path, self.io) catch |err| {
            std.Io.Dir.deleteFileAbsolute(self.io, tmp_path) catch {};
            return err;
        };
    }

    /// Lazily build (and cache) the decode pipeline for `format`.
    fn ensureDecoder(self: *Self, format: *const pie.graphs.Format) !*Decoder {
        const slot = try self.decoders.getOrPut(self.allocator, format.source_module);
        if (slot.found_existing) return slot.value_ptr.*;
        errdefer _ = self.decoders.remove(format.source_module);

        const decoder = try self.allocator.create(Decoder);
        errdefer self.allocator.destroy(decoder);

        decoder.pipeline = try pie.Pipeline.init(self.allocator, self.io, self.gpu, .{
            .upload_buffer_size_bytes = 96 * 1024 * 1024,
            .download_buffer_size_bytes = 8 * 1024 * 1024,
        });
        errdefer decoder.pipeline.deinit();

        // The graph's sink is re-pointed at each entry's cache file, so this
        // path only has to end the graph in a file sink.
        const graph = try pie.graphs.recommendFormat(&decoder.pipeline, format, .{
            .max_edge = thumb_px,
            .output_path = cache_placeholder,
            .output_module = cache_module,
        });
        decoder.source = graph.source;
        decoder.sink = graph.sink;

        slot.value_ptr.* = decoder;
        return decoder;
    }

    // ------------------------------------------------------------------------
    // worker
    // ------------------------------------------------------------------------

    fn startWorker(self: *Self) void {
        self.stop.store(false, .release);
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            slog.err("cannot start the thumbnail worker: {s}", .{@errorName(err)});
            return;
        };
    }

    fn stopWorker(self: *Self) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Render every pending entry of this scan. Entries and their paths stay
    /// valid until `stopWorker` joins us; the hand-off to the main thread is a
    /// single atomic publish per entry.
    fn workerMain(self: *Self) void {
        for (self.entries) |*entry| {
            if (self.stop.load(.acquire)) return;
            if (entry.status.load(.acquire) != Status.pending) continue;

            entry.status.store(Status.rendering, .release);
            self.renderEntry(entry) catch |err| {
                slog.warn("thumbnail for '{s}' failed: {s}", .{ entry.path, @errorName(err) });
                entry.status.store(Status.failed, .release);
                continue;
            };
            entry.status.store(Status.cached, .release);
        }
    }

    /// Fallback used only when `startWorker` failed: render at most one
    /// pending thumbnail on the main thread so thumbnails still appear.
    fn renderPendingOnMainThread(self: *Self) void {
        for (self.entries) |*entry| {
            if (entry.status.load(.acquire) != Status.pending) continue;
            entry.status.store(Status.rendering, .release);
            self.renderEntry(entry) catch |err| {
                slog.warn("thumbnail for '{s}' failed: {s}", .{ entry.path, @errorName(err) });
                entry.status.store(Status.failed, .release);
                return;
            };
            entry.status.store(Status.cached, .release);
            return;
        }
    }

    /// Main thread: load a rendered cache file and inject it into sokol.
    fn uploadEntry(self: *Self, entry: *Entry) !void {
        const cache_path = try self.cachePath(entry.path);
        defer self.allocator.free(cache_path);

        const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), self.io, cache_path, self.allocator, .unlimited);
        defer self.allocator.free(bytes);

        var image = try zigimg.Image.fromMemory(self.allocator, bytes);
        defer image.deinit(self.allocator);
        if (image.width == 0 or image.height == 0) return error.EmptyImage;
        try image.convert(self.allocator, .rgba32);
        const rgba = std.mem.sliceAsBytes(image.pixels.rgba32);

        entry.width = @intCast(image.width);
        entry.height = @intCast(image.height);
        entry.image = sg.makeImage(.{
            .width = @intCast(entry.width),
            .height = @intCast(entry.height),
            .pixel_format = .RGBA8,
            .data = .{ .mip_levels = init: {
                var levels: [16]sg.Range = @splat(.{});
                levels[0] = sg.asRange(rgba);
                break :init levels;
            } },
            .label = "catalog-thumbnail",
        });
        entry.view = sg.makeView(.{
            .texture = .{ .image = entry.image },
            .label = "catalog-thumbnail-view",
        });
        entry.texture = simgui.imtextureid(entry.view);
    }
};

fn lessByName(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Absolute, symlink-resolved path of `dir` (which must exist). Owned by the
/// caller. The catalog keeps this so the lighttable can show, and the folder
/// picker can seed itself with, a full path.
fn absoluteDir(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) ![]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, allocator);
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}
