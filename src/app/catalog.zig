//! Image catalog behind the lighttable.
//!
//! Scans a directory and decodes thumbnails on a worker thread; the main thread
//! uploads them. The split is deliberate: sokol-gfx resources must be created on
//! the render thread, while decoding a RAW is slow enough to be worth a thread.
//! The worker never touches GPU state and the main thread never blocks on a
//! decode — `tick` only moves finished work along.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const simgui = sokol.imgui;
const libraw = @import("libraw");
const zigimg = @import("zigimg");

const slog = std.log.scoped(.catalog);

/// longest edge of a generated thumbnail, in pixels
pub const thumb_px: u32 = 256;

/// Entry lifecycle. The worker publishes `decoding` then `ready`/`failed`; the
/// main thread consumes `ready` and moves it to `uploaded`. One writer per
/// transition, published with release/acquire, so no lock is needed.
pub const Status = enum(u8) { pending, decoding, ready, uploaded, failed };

pub const Pixels = struct {
    data: []u8,
    width: u32,
    height: u32,
};

pub const Entry = struct {
    /// file name, for display
    name: []u8,
    /// path handed to the pipeline when the entry is opened
    path: []u8,
    /// written by the worker before it publishes `ready`/`failed`
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.pending)),
    /// decoded RGBA8 pixels, handed from the worker to the main thread
    pixels: ?Pixels = null,
    /// uploaded thumbnail, owned by the main thread
    image: sg.Image = .{},
    view: sg.View = .{},
    /// ImTextureID for `igImage`; 0 until ready
    texture: u64 = 0,
    /// set once the failure has been published in a model revision
    reported: bool = false,
    /// size of the uploaded thumbnail
    thumb_width: u32 = 0,
    thumb_height: u32 = 0,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// directory that was scanned
    dir: []u8,
    entries: []Entry = &.{},
    /// bumped whenever the visible content changes, so the host can rebuild the
    /// lighttable model
    revision: u32 = 0,

    // worker bookkeeping. One thread per scan: it walks the entries slice once
    // and exits, so no queue, no condition variable and no mutex are needed (the
    // slice is stable for the thread's lifetime, see `reload`).
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// pixel buffers that were already handed to sokol; freed on the next tick,
    /// once a commit had the chance to read them
    retired: std.ArrayListUnmanaged([]u8) = .empty,

    const Self = @This();

    /// Heap-allocated on purpose: the worker thread holds a pointer to it.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .dir = try allocator.dupe(u8, dir) };
        errdefer allocator.free(self.dir);

        try self.scan();
        self.startWorker();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stopWorker();
        self.destroyThumbnails();
        self.freeEntries();
        for (self.retired.items) |buf| self.allocator.free(buf);
        self.retired.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.allocator.destroy(self);
    }

    /// Rescan the directory, dropping the current thumbnails.
    pub fn reload(self: *Self) void {
        self.stopWorker();
        self.destroyThumbnails();
        self.freeEntries();
        self.entries = &.{};
        self.stop.store(false, .release);

        self.scan() catch |err| slog.err("rescan of '{s}' failed: {s}", .{ self.dir, @errorName(err) });
        self.startWorker();
        self.revision += 1;
    }

    /// Main thread: upload any decoded thumbnails, release the buffers that are
    /// past their commit, and decode at most one pending RAW thumbnail (one per
    /// frame keeps the UI responsive, and doing it here keeps it off libraw).
    pub fn tick(self: *Self) void {
        for (self.retired.items) |buf| self.allocator.free(buf);
        self.retired.clearRetainingCapacity();

        self.decodePendingRaw();

        var uploaded: usize = 0;
        for (self.entries) |*entry| {
            const status: Status = @enumFromInt(entry.status.load(.acquire));
            const pixels = switch (status) {
                .ready => entry.pixels orelse continue,
                .failed => {
                    if (!entry.reported) {
                        entry.reported = true;
                        self.revision += 1;
                    }
                    continue;
                },
                else => continue,
            };
            entry.pixels = null;

            entry.image = sg.makeImage(.{
                .width = @intCast(pixels.width),
                .height = @intCast(pixels.height),
                .pixel_format = .RGBA8,
                .data = .{ .mip_levels = init: {
                    var levels: [16]sg.Range = @splat(.{});
                    levels[0] = sg.asRange(pixels.data);
                    break :init levels;
                } },
                .label = "catalog-thumbnail",
            });
            entry.thumb_width = pixels.width;
            entry.thumb_height = pixels.height;
            entry.view = sg.makeView(.{ .texture = .{ .image = entry.image }, .label = "catalog-thumbnail-view" });
            entry.texture = simgui.imtextureid(entry.view);
            entry.status.store(@intFromEnum(Status.uploaded), .release);

            self.retired.append(self.allocator, pixels.data) catch self.allocator.free(pixels.data);
            uploaded += 1;
        }

        if (uploaded > 0) self.revision += 1;
    }

    /// Is the thumbnail for `index` ready to be drawn?
    pub fn textureOf(self: *const Self, index: usize) u64 {
        if (index >= self.entries.len) return 0;
        return self.entries[index].texture;
    }

    pub fn thumbSize(self: *const Self, index: usize) [2]u32 {
        if (index >= self.entries.len) return .{ 0, 0 };
        return .{ self.entries[index].thumb_width, self.entries[index].thumb_height };
    }

    pub fn entryState(self: *const Self, index: usize) struct { failed: bool, ready: bool } {
        if (index >= self.entries.len) return .{ .failed = false, .ready = false };
        const status: Status = @enumFromInt(self.entries[index].status.load(.acquire));
        return .{
            .failed = status == .failed,
            // `uploaded` means the texture is there too
            .ready = status == .ready or status == .uploaded,
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
            if (!isImageFile(dirent.name)) continue;

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
            entry.status.store(@intFromEnum(Status.pending), .release);
            entry.reported = false;
            if (entry.pixels) |pixels| {
                self.allocator.free(pixels.data);
                entry.pixels = null;
            }
        }
    }

    fn decodePendingRaw(self: *Self) void {
        for (self.entries) |*entry| {
            const status: Status = @enumFromInt(entry.status.load(.acquire));
            if (status != .pending) continue;
            if (!isRawExtension(entry.path)) continue;

            entry.status.store(@intFromEnum(Status.decoding), .release);
            const decoded = decodeThumbnail(self.allocator, self.io, entry.path) catch |err| {
                slog.warn("thumbnail for '{s}' failed: {s}", .{ entry.path, @errorName(err) });
                entry.status.store(@intFromEnum(Status.failed), .release);
                return;
            };
            entry.pixels = decoded;
            entry.status.store(@intFromEnum(Status.ready), .release);
            return;
        }
    }

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

    /// Decode every entry of the scan this thread was started for. Entries and
    /// their paths stay valid until `stopWorker` joins us; the hand-off to the
    /// main thread is a single publish (`pixels` then `status`), so there is
    /// nothing to lock.
    fn workerMain(self: *Self) void {
        for (self.entries, 0..) |*entry, index| {
            if (self.stop.load(.acquire)) return;
            // RAW files are decoded by `decodePendingRaw` on the main thread:
            // libraw keeps global state and the pipeline decodes raws with it as
            // well, so the two must never be in flight at the same time.
            if (isRawExtension(entry.path)) continue;

            entry.status.store(@intFromEnum(Status.decoding), .release);
            const path = entry.path;

            const decoded = decodeThumbnail(self.allocator, self.io, path) catch |err| {
                slog.warn("thumbnail for '{s}' failed: {s}", .{ path, @errorName(err) });
                self.entries[index].status.store(@intFromEnum(Status.failed), .release);
                continue;
            };

            // publish: pixels first, then the status that points at them
            entry.pixels = decoded;
            entry.status.store(@intFromEnum(Status.ready), .release);
        }
    }
};

fn lessByName(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn isImageFile(name: []const u8) bool {
    return hasExtension(name, &.{
        "nef", "cr2", "cr3",  "arw",  "dng", "raf", "rw2", "orf", "pef", "srw", "nrw", "raw",
        "png", "jpg", "jpeg", "tif",  "tiff", "bmp", "ppm", "gif",
    });
}


fn hasExtension(name: []const u8, extensions: []const []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    const bare = ext[1..]; // skip the dot
    for (extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(bare, candidate)) return true;
    }
    return false;
}

fn isRawExtension(name: []const u8) bool {
    return hasExtension(name, &.{ "nef", "cr2", "cr3", "arw", "dng", "raf", "rw2", "orf", "pef", "srw", "nrw", "raw" });
}

// ----------------------------------------------------------------------------
// decoding (worker thread)
// ----------------------------------------------------------------------------

fn decodeThumbnail(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Pixels {
    if (isRawExtension(path)) return decodeRaw(allocator, path);
    return decodeImageFile(allocator, io, path);
}

/// Anything zigimg can read: png/jpeg/tiff/… and the embedded JPEG previews of
/// RAW files.
fn decodeImageFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Pixels {
    const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return decodeWithZigimg(allocator, bytes);
}

fn decodeWithZigimg(allocator: std.mem.Allocator, bytes: []const u8) !Pixels {
    var image = try zigimg.Image.fromMemory(allocator, bytes);
    defer image.deinit(allocator);
    if (image.width == 0 or image.height == 0) return error.EmptyImage;

    try image.convert(allocator, .rgba32);
    const rgba = std.mem.sliceAsBytes(image.pixels.rgba32);
    return downscaleFrom(allocator, rgba, @intCast(image.width), @intCast(image.height), 4, 8);
}

/// RAW files: prefer the embedded preview — it is what a lighttable should show
/// and it avoids demosaicing tens of megapixels. Fall back to a full demosaic
/// when the file has no usable preview.
fn decodeRaw(allocator: std.mem.Allocator, path: []const u8) !Pixels {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return error.PathTooLong;

    const handle = libraw.libraw_init(0);
    if (handle == null) return error.LibRawInitFailed;
    defer libraw.libraw_close(handle);

    if (libraw.libraw_open_file(handle, path_z.ptr) != libraw.LIBRAW_SUCCESS) return error.OpenFailed;

    // 1. the embedded preview: cheap, and what a lighttable should show
    var error_code: c_int = 0;
    if (libraw.libraw_unpack_thumb(handle) == libraw.LIBRAW_SUCCESS) {
        const thumb = libraw.libraw_dcraw_make_mem_thumb(handle, &error_code);
        if (thumb != null) {
            defer libraw.libraw_dcraw_clear_mem(thumb);
            if (decodeProcessed(allocator, thumb)) |pixels| {
                return pixels;
            } else |err| {
                slog.debug("embedded preview of '{s}' unusable ({s}), decoding the raw instead", .{ path, @errorName(err) });
            }
        }
    } else {
        slog.debug("'{s}' has no embedded preview ({d} in file), decoding the raw instead", .{
            path, handle.*.thumbs_list.thumbcount,
        });
    }

    // 2. full decode. A lighttable thumbnail does not need interpolation, so ask
    // libraw for the half-size image: one output pixel per CFA quad, no demosaic
    // pass — much cheaper than the default quality path.
    handle.*.params.half_size = 1;
    handle.*.params.output_bps = 8;
    if (libraw.libraw_unpack(handle) != libraw.LIBRAW_SUCCESS) return error.UnpackFailed;
    if (libraw.libraw_dcraw_process(handle) != libraw.LIBRAW_SUCCESS) return error.ProcessFailed;
    const image = libraw.libraw_dcraw_make_mem_image(handle, &error_code);
    if (image == null) return error.MakeMemImageFailed;
    defer libraw.libraw_dcraw_clear_mem(image);
    return decodeProcessed(allocator, image);
}

/// A `libraw_processed_image_t` holds either raw pixels or a JPEG stream.
fn decodeProcessed(allocator: std.mem.Allocator, image: [*c]libraw.libraw_processed_image_t) !Pixels {
    const width: u32 = image.*.width;
    const height: u32 = image.*.height;
    if (width == 0 or height == 0) return error.EmptyImage;

    const data: [*]const u8 = @ptrCast(&image.*.data);
    const size: usize = image.*.data_size;

    if (image.*.type == libraw.LIBRAW_IMAGE_JPEG) return decodeWithZigimg(allocator, data[0..size]);
    if (image.*.type != libraw.LIBRAW_IMAGE_BITMAP) return error.UnsupportedImageType;

    return downscaleFrom(allocator, data[0..size], width, height, image.*.colors, image.*.bits);
}

/// Box-filter `src` (tightly packed, `colors` components of `bits` each) down so
/// its longest edge is at most `thumb_px`, emitting RGBA8.
fn downscaleFrom(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: u32,
    height: u32,
    colors: u32,
    bits: u32,
) !Pixels {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (colors != 3 and colors != 4) return error.UnsupportedColors;
    const component_bytes: u32 = bits / 8;
    if (component_bytes == 0 or component_bytes > 2) return error.UnsupportedBits;

    const row_bytes: usize = @as(usize, width) * colors * component_bytes;
    if (src.len < row_bytes * height) return error.ShortBuffer;

    const longest = @max(width, height);
    const scale = @min(1.0, @as(f32, @floatFromInt(thumb_px)) / @as(f32, @floatFromInt(longest)));
    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * scale)));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * scale)));

    var out = try allocator.alloc(u8, @as(usize, out_w) * out_h * 4);
    errdefer allocator.free(out);

    for (0..out_h) |oy| {
        const y0 = @as(u32, @intCast(oy)) * height / out_h;
        const y1 = @max(y0 + 1, (@as(u32, @intCast(oy)) + 1) * height / out_h);
        for (0..out_w) |ox| {
            const x0 = @as(u32, @intCast(ox)) * width / out_w;
            const x1 = @max(x0 + 1, (@as(u32, @intCast(ox)) + 1) * width / out_w);

            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            var count: u32 = 0;
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const base = @as(usize, y) * row_bytes + @as(usize, x) * colors * component_bytes;
                    acc[0] += component(src, base, component_bytes);
                    acc[1] += component(src, base + component_bytes, component_bytes);
                    acc[2] += component(src, base + 2 * component_bytes, component_bytes);
                    acc[3] += if (colors == 4) component(src, base + 3 * component_bytes, component_bytes) else 255;
                    count += 1;
                }
            }

            const dst = (@as(usize, @intCast(oy)) * out_w + @as(usize, @intCast(ox))) * 4;
            out[dst + 0] = @intCast(acc[0] / count);
            out[dst + 1] = @intCast(acc[1] / count);
            out[dst + 2] = @intCast(acc[2] / count);
            out[dst + 3] = @intCast(acc[3] / count);
        }
    }

    return .{ .data = out, .width = out_w, .height = out_h };
}

/// 8-bit components pass through; 16-bit ones are big-endian, so the high byte
/// is the 8-bit value.
fn component(src: []const u8, offset: usize, component_bytes: u32) u32 {
    return switch (component_bytes) {
        1 => src[offset],
        2 => (@as(u32, src[offset]) << 8) | src[offset + 1],
        else => 0,
    };
}
