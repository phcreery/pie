const std = @import("std");
const slog = std.log.scoped(.@"i-raw");
const image = @import("image_libraw.zig");
const RawImage = @import("RawImage.zig");

const api = @import("../api.zig");
const math = @import("math");

const WbMode = enum(i32) {
    cam_mul = 0, // White balance coefficients (as shot). Either read from file or calculated.
    pre_mul = 1, // White balance coefficients for daylight (daylight balance). Either read from file, or calculated on the basis of file data, or taken from hardcoded constants.
};

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "i-raw",
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
                .type = .source,
                .format = .rggb16uint,
                // the raw output is in the camera's color space, WB unknown/as-shot,
                // and linear (sensor response)
                .color_profile = .{ .white_point = .any, .primaries = .camera, .trc = .linear },
            },
        },
    },
    .initParams = initParams,
    .init = init,
    .deinit = deinit,
    .modifyOut = modifyOut,
    .createNodes = createNodes,
    .readSource = readSource,
};

/// The raw image plus the path it came from, so `modifyOut` can notice a
/// changed `filename` param and reload without a full pipeline reroute.
const Loaded = struct {
    raw: RawImage,
    path: []u8,
};

fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const raw = try image.read(allocator, io, path);
    return .{ .raw = raw, .path = owned_path };
}

fn loadedOf(mod: *api.Module) ?*Loaded {
    const data_ptr = mod.data orelse return null;
    return @ptrCast(@alignCast(data_ptr));
}

fn unload(allocator: std.mem.Allocator, mod: *api.Module) void {
    const loaded = loadedOf(mod) orelse return;
    image.deinit(&loaded.raw);
    allocator.free(loaded.path);
    allocator.destroy(loaded);
    mod.data = null;
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, pipe: api.PipelineHandle, mod_handle: api.ModuleHandle) !void {
    const filename = try api.getParam(pipe, mod_handle, "filename", []const u8);
    if (filename.len == 0) return;
    slog.info("i-raw filename: {s}", .{filename});

    const loaded = try allocator.create(Loaded);
    errdefer allocator.destroy(loaded);
    loaded.* = try load(allocator, io, filename);

    const mod = try api.getModule(pipe, mod_handle);
    mod.data = loaded;
}

pub fn deinit(allocator: std.mem.Allocator, pipe: api.PipelineHandle, mod: api.ModuleHandle) void {
    const m = api.getModule(pipe, mod) catch return;
    unload(allocator, m);
}

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParam(pipe, mod, "filename", @as([]const u8, "input.raw"));
}

fn computeRec2020FromCam(raw_image: *RawImage) [3][3]f32 {
    const xyz_from_cam = math.Mat3(f32).fromArray(raw_image.xyz_d65_from_cam);
    const rec2020_from_xyz_d65 = math.matrices.rec2020_from_xyz_d65;

    const rec2020_from_cam = rec2020_from_xyz_d65.mul(xyz_from_cam);
    return rec2020_from_cam.toArray();
}

fn normalizeWhiteBalance(wb: [4]f32) [4]f32 {
    const green_ref = blk: {
        if (wb[1] > 0.0) break :blk wb[1];
        if (wb[3] > 0.0) break :blk wb[3];
        break :blk 1.0;
    };

    var out = wb;
    out[0] = if (wb[0] > 0.0) wb[0] / green_ref else 1.0;
    out[1] = 1.0;
    out[2] = if (wb[2] > 0.0) wb[2] / green_ref else 1.0;
    // Treat the 4th slot as G2. If LibRaw leaves it unset/zero, use the same normalized gain as G1.
    out[3] = 1.0;
    return out;
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);
    const filename = try api.getParam(pipe, mod, "filename", []const u8);

    // Reload when the file changed. `init` only runs on a reroute, so this is
    // what lets a cached pipeline (and the editor) open another image.
    const stale = if (loadedOf(m)) |loaded| !std.mem.eql(u8, loaded.path, filename) else true;
    if (stale) {
        unload(pipe.allocator, m);
        if (filename.len > 0) {
            const loaded = pipe.allocator.create(Loaded) catch |err| {
                slog.err("cannot allocate raw image state: {s}", .{@errorName(err)});
                return;
            };
            loaded.* = load(pipe.allocator, pipe.io, filename) catch |err| {
                slog.err("cannot decode '{s}': {s}", .{ filename, @errorName(err) });
                pipe.allocator.destroy(loaded);
                return;
            };
            m.data = loaded;
        }
    }

    const loaded = loadedOf(m) orelse return error.ModuleDataMissing;
    const raw_image = &loaded.raw;

    const roi: api.ROI = .{
        .w = @intCast(raw_image.width),
        .h = @intCast(raw_image.height),
    };
    // NOTE: single-channel rggb storage (one photosite per texel), so the
    // ROI is the true photosite dimensions of the sensor.

    const selected_wb = normalizeWhiteBalance(raw_image.wb_coeffs);
    // as a sanity check, libraw's pre_mul with the auto white balance applied should result in 1,1,1 coeffs
    // const selected_wb = normalizeWhiteBalance(raw_image.pre_mul);

    var orientation: api.ImgParam.Orientation = .normal;
    if (raw_image.user_flip != -1) {
        orientation = switch (raw_image.user_flip) {
            1 => .normal,
            3 => .rotate180,
            5 => .rotate270CW,
            6 => .rotate90CW,
            8 => .rotate270CW,
            else => blk: {
                slog.warn("Unknown orientation value {d}, defaulting to normal", .{raw_image.orientation});
                break :blk .normal;
            },
        };
    } else {
        orientation = switch (raw_image.orientation) {
            1 => .normal,
            3 => .rotate180,
            5 => .rotate270CW,
            6 => .rotate90CW,
            8 => .rotate270CW,
            else => blk: {
                slog.warn("Unknown orientation value {d}, defaulting to normal", .{raw_image.orientation});
                break :blk .normal;
            },
        };
    }

    m.img_param = .{
        .black = [4]f32{
            @as(f32, @floatFromInt(raw_image.black[0])),
            @as(f32, @floatFromInt(raw_image.black[1])),
            @as(f32, @floatFromInt(raw_image.black[2])),
            @as(f32, @floatFromInt(raw_image.black[3])),
        },
        .white = [4]f32{
            @as(f32, @floatFromInt(raw_image.white[0])),
            @as(f32, @floatFromInt(raw_image.white[1])),
            @as(f32, @floatFromInt(raw_image.white[2])),
            @as(f32, @floatFromInt(raw_image.white[3])),
        },
        .white_balance = selected_wb,
        .orientation = orientation,
        .rec2020_from_cam = computeRec2020FromCam(raw_image),
        .xyz_d65_from_cam = raw_image.xyz_d65_from_cam,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(pipe.io, &stdout_buffer);
    const stdout = &writer.interface;
    try raw_image.print(stdout);
    try m.img_param.?.print(stdout);
    try stdout.flush();

    var socket = try api.getModSocket(pipe, mod, "output");
    socket.roi = roi;
}

pub fn readSource(pipe: api.PipelineHandle, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    const m = try api.getModule(pipe, mod);
    const loaded = loadedOf(m) orelse return error.ModuleDataMissing;
    const raw_image = &loaded.raw;

    // raw_image is row-contiguous u16; stage it into the padded upload layout
    api.copyToStaging(
        mapped,
        std.mem.sliceAsBytes(raw_image.raw_image),
        @intCast(raw_image.width),
        @intCast(raw_image.height),
        @sizeOf(u16),
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
                try api.copyModSocket(def.desc, "output"),
            },
        },
    );
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
