const std = @import("std");
const slog = std.log.scoped(.@"i-png");
const stbi = @import("stbi");
const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "i-png",
    .type = .source,
    .params = &.{
        .{ .name = "filename", .len = 256, .typ = .str },
    },
    .params_ui = &.{
        .{ .name = "filename", .control = .{ .readonly = {} } },
    },
    .sockets = &.{
        .{
            .name = "output",
            // raw 16-bit samples; the `format` module converts to f16 on
            // the GPU, so the CPU never touches the samples
            .type = .source,
            .format = .rgba16uint,
            .color_profile = .any,
        },
    },
    .initParams = initParams,
    .init = init,
    .deinit = deinit,
    .modifyOut = modifyOut,
    .createNodes = createNodes,
    .readSource = readSource,
};

/// Module-private data (`mod.data`): the decoded image plus the path it came
/// from, so `modifyOut` can tell when a reload is needed.
///
/// `pixels` is always tightly packed RGBA **u16** (4 channels) matching the
/// `rgba16uint` socket, so `readSource` is a plain copy.
const Loaded = struct {
    width: u32,
    height: u32,
    pixels: []u16,
    path: []u8,
};

fn freeLoaded(allocator: std.mem.Allocator, data_ptr: *anyopaque) void {
    const loaded = @as(*Loaded, @ptrCast(@alignCast(data_ptr)));
    allocator.free(loaded.path);
    allocator.free(loaded.pixels);
    allocator.destroy(loaded);
}

/// Decode `path` into tightly packed RGBA u16 via the optimized stb_image
/// library; 8-bit sources are scaled to 16-bit.
fn load(allocator: std.mem.Allocator, path: []const u8) !Loaded {
    var image = stbi.decode16(allocator, path, 4) catch |err| {
        slog.warn("stb_image failed on '{s}': {s} ({s})", .{ path, @errorName(err), stbi.failureReason() });
        return err;
    };
    errdefer image.deinit(allocator);

    const path_copy = try allocator.dupe(u8, path);
    return .{
        .width = image.width,
        .height = image.height,
        // take ownership of the samples
        .pixels = image.pixels,
        .path = path_copy,
    };
}

/// Free whatever is currently loaded and decode `filename` in its place.
fn reload(allocator: std.mem.Allocator, mod: *api.Module, filename: []const u8) !void {
    if (mod.data) |data_ptr| {
        freeLoaded(allocator, data_ptr);
        mod.data = null;
    }

    const loaded = try allocator.create(Loaded);
    errdefer allocator.destroy(loaded);
    loaded.* = try load(allocator, filename);
    mod.data = loaded;
}

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "filename", @as([]const u8, ""));
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, pipe: api.PipelineHandle, mod_handle: api.ModuleHandle) !void {
    _ = io;
    const filename = try api.getParam(pipe, mod_handle, "filename", []const u8);
    // nothing selected yet; the first `modifyOut` with a real path does the load
    if (filename.len == 0) return;

    const mod = try api.getModule(pipe, mod_handle);
    // `init` re-runs on every reroute; keep the already-loaded pixels unless
    // the selected file changed.
    if (mod.data) |data_ptr| {
        const loaded = @as(*Loaded, @ptrCast(@alignCast(data_ptr)));
        if (std.mem.eql(u8, loaded.path, filename)) return;
    }
    try reload(allocator, mod, filename);
}

pub fn deinit(allocator: std.mem.Allocator, pipe: api.PipelineHandle, mod_handle: api.ModuleHandle) void {
    const mod = api.getModule(pipe, mod_handle) catch return;
    const data_ptr = mod.data orelse return;
    freeLoaded(allocator, data_ptr);
    mod.data = null;
}

pub fn modifyOut(pipe: api.PipelineHandle, mod_handle: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod_handle);
    const filename = try api.getParam(pipe, mod_handle, "filename", []const u8);

    if (filename.len == 0) {
        // no file selected: drop anything previously loaded
        if (m.data) |data_ptr| {
            freeLoaded(pipe.allocator, data_ptr);
            m.data = null;
        }
        return;
    }

    const needs_reload = blk: {
        const data_ptr = m.data orelse break :blk true;
        const loaded = @as(*Loaded, @ptrCast(@alignCast(data_ptr)));
        break :blk !std.mem.eql(u8, loaded.path, filename);
    };

    if (needs_reload) {
        reload(pipe.allocator, m, filename) catch return;
    }

    const data_ptr = m.data orelse return;
    const loaded = @as(*Loaded, @ptrCast(@alignCast(data_ptr)));

    var socket = try api.getModSocket(pipe, mod_handle, "output");
    socket.roi = .{
        .w = loaded.width,
        .h = loaded.height,
    };

    // a PNG is already display-referred; identity through the pipeline
    const identity_3x3: [3][3]f32 = .{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };
    m.img_param = .{
        .black = .{ 1.0, 1.0, 1.0, 1.0 },
        .white = .{ 1.0, 1.0, 1.0, 1.0 },
        .white_balance = .{ 1.0, 1.0, 1.0, 1.0 },
        .orientation = .normal,
        .srgb_from_cam = identity_3x3,
        .xyz_d65_from_cam = identity_3x3,
    };
}

pub fn readSource(pipe: api.PipelineHandle, mod_handle: api.ModuleHandle, mapped: *anyopaque) !void {
    const m = try api.getModule(pipe, mod_handle);
    const data_ptr = m.data orelse return error.ModuleDataMissing;
    const loaded = @as(*Loaded, @ptrCast(@alignCast(data_ptr)));

    // `pixels` is already row-contiguous RGBA u16; stage it as-is.
    api.copyToStaging(
        mapped,
        std.mem.sliceAsBytes(loaded.pixels),
        loaded.width,
        loaded.height,
        @sizeOf(u16) * 4,
    );
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const node = try api.addNode(
        pipe,
        mod,
        .{
            .type = .source,
            .name = "source",
            .sockets = &.{
                try api.copyModSocket(desc, "output"),
            },
        },
    );
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
