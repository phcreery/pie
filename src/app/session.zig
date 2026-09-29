//! Editing session: owns the editor pipeline, the blit resources and the image
//! catalog behind the lighttable.
//! GPU work (running the pipeline, decoding a thumbnail) must not happen inside the ImGui
//! frame or the render pass, so the GUI queues requests here and `tick` applies
//! them before the frame starts.

const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const pie = @import("pie");

const Blit = @import("blit.zig").Blit;
/// A framebuffer-pixel region: where the image is allowed to draw.
pub const Rect = @import("blit.zig").Rect;
const Catalog = @import("catalog.zig").Catalog;
const nfd = @import("nfd");

const slog = std.log.scoped(.session);

pub const input_filename = "testing/images/DSC_6765.NEF";

/// Where rendered thumbnails are cached: `$XDG_CACHE_HOME/pie/thumbs` (or
/// `~/.cache/pie/thumbs`). Returns an owned path.
pub fn resolveCacheDir(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    if (environ_map.get("XDG_CACHE_HOME")) |root| {
        if (root.len > 0) return std.fs.path.join(allocator, &.{ root, "pie", "thumbs" });
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(allocator, &.{ home, ".cache", "pie", "thumbs" });
    }
    return allocator.dupe(u8, ".pie-thumbs");
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gpu: *pie.GPU,

    /// the pipeline the darkroom edits
    pipeline: pie.Pipeline,
    blit: Blit,
    /// images the lighttable lists
    catalog: *Catalog,

    /// file currently loaded in the editor pipeline
    source_path: []u8,

    built: bool = false,
    needs_run: bool = false,

    /// Deferred GUI requests, applied in `tick` (outside the render pass).
    pending_open: ?u32 = null,
    pending_reload: bool = false,
    pending_browse: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        gpu: *pie.GPU,
        cache_dir: []const u8,
    ) !Self {
        var pipeline = try pie.Pipeline.init(allocator, io, gpu, null);
        errdefer pipeline.deinit();

        const dir = std.fs.path.dirname(input_filename) orelse ".";
        const catalog = try Catalog.init(allocator, io, dir, cache_dir, gpu);
        errdefer catalog.deinit();

        const source_path = try allocator.dupe(u8, input_filename);
        errdefer allocator.free(source_path);

        return .{
            .allocator = allocator,
            .io = io,
            .gpu = gpu,
            .pipeline = pipeline,
            .blit = Blit.init(),
            .catalog = catalog,
            .source_path = source_path,
        };
    }

    pub fn deinit(self: *Self) void {
        nfd.deinit();
        self.blit.deinit();
        self.catalog.deinit();
        self.pipeline.deinit();
        self.allocator.free(self.source_path);
    }

    /// Per-frame host work: apply deferred GUI requests, then move catalog
    /// thumbnails along. MUST run before `simgui.newFrame` (it submits GPU work).
    pub fn tick(self: *Self) void {
        if (self.pending_browse) {
            self.pending_browse = false;
            self.browseCatalogNow();
        }
        if (self.pending_reload) {
            self.pending_reload = false;
            self.reloadCatalogNow();
        }
        if (self.pending_open) |index| {
            self.pending_open = null;
            self.openImageNow(index);
        }
        self.catalog.tick();
    }

    /// Build and run the editor graph on the first frame. Errors are reported
    /// and retried next frame rather than taking the app down.
    pub fn ensureBuilt(self: *Self) bool {
        if (self.built) return true;
        self.buildEditorGraph() catch |err| {
            slog.err("could not build the editor pipeline: {s}", .{@errorName(err)});
            return false;
        };
        self.run() catch |err| {
            slog.err("could not run the editor pipeline: {s}", .{@errorName(err)});
            return false;
        };
        self.built = true;
        return true;
    }

    /// Rebuild the editor graph for `source_path` using the engine's
    /// recommended pipeline for that file type.
    fn buildEditorGraph(self: *Self) !void {
        self.pipeline.clear();
        _ = try pie.graphs.recommend(&self.pipeline, self.source_path, .{});
    }

    /// Run the editor pipeline and publish the (possibly new) display texture.
    pub fn run(self: *Self) !void {
        try self.pipeline.run();
        const texture = try self.pipeline.getDisplaySinkTexture();
        self.blit.setTexture(texture);
    }

    /// True if something asked the editor pipeline to be re-run this frame.
    pub fn consumeRun(self: *Self) bool {
        const requested = self.needs_run;
        self.needs_run = false;
        return requested;
    }

    pub fn requestRun(self: *Self) void {
        self.needs_run = true;
    }

    /// Write a module parameter and mark the pipeline dirty.
    pub fn setParam(
        self: *Self,
        handle: pie.pipeline.ModuleHandle,
        name: []const u8,
        T: type,
        value: T,
    ) void {
        self.pipeline.setModuleParam(handle, name, T, value) catch |err| {
            slog.warn("set_param '{s}' failed: {s}", .{ name, @errorName(err) });
            return;
        };
        self.needs_run = true;
    }

    /// Load catalog entry `index` into the editor (applied in `tick`).
    pub fn openImage(self: *Self, index: u32) void {
        self.pending_open = index;
    }

    /// Rescan the catalog directory (applied in `tick`).
    pub fn reloadCatalog(self: *Self) void {
        self.pending_reload = true;
    }

    /// Ask for a new catalog directory with the platform's folder picker
    /// (applied in `tick`, which may block until the user answers).
    pub fn browseCatalog(self: *Self) void {
        self.pending_browse = true;
    }

    /// The modal dialog blocks, so this runs in `tick`: the frame that asked for
    /// it has already been submitted, and no render pass is open while the
    /// catalog swaps its GPU thumbnails.
    fn browseCatalogNow(self: *Self) void {
        const picked = nfd.pickFolder(self.allocator, self.catalog.dir) orelse return;
        defer self.allocator.free(picked);

        self.catalog.setDir(picked) catch |err| {
            slog.warn("cannot list '{s}': {s}", .{ picked, @errorName(err) });
            return;
        };
        slog.info("catalog directory is now '{s}'", .{picked});
    }

    fn openImageNow(self: *Self, index: u32) void {
        if (index >= self.catalog.entries.len) return;
        const path = self.catalog.entries[index].path;
        if (std.mem.eql(u8, path, self.source_path)) return;

        const copy = self.allocator.dupe(u8, path) catch |err| {
            slog.err("cannot open '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        self.allocator.free(self.source_path);
        self.source_path = copy;

        self.buildEditorGraph() catch |err| {
            slog.err("cannot build the pipeline for '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        self.needs_run = true;
        slog.info("opening '{s}'", .{path});
    }

    fn reloadCatalogNow(self: *Self) void {
        slog.info("reloading the catalog", .{});
        self.catalog.reload();
    }
};
