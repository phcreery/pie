const std = @import("std");
const slog = std.log.scoped(.@"i-raw");
const RawImage = @import("libraw_image.zig").RawImage;

const api = @import("../api.zig");

const WbMode = enum(i32) {
    cam_mul = 0, // White balance coefficients (as shot). Either read from file or calculated.
    pre_mul = 1, // White balance coefficients for daylight (daylight balance). Either read from file, or calculated on the basis of file data, or taken from hardcoded constants.
};

pub var desc: api.ModuleDesc = .{
    .name = "i-raw",
    .type = .source,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "filename", .len = 256, .typ = .str };
        p[1] = .{ .name = "wb_mode", .len = 1, .typ = .i32 };
        break :init p;
    },
    .params_ui = init: {
        var ui: [api.MAX_PARAMS_PER_MODULE]?api.ParamUI = @splat(null);
        ui[0] = .{ .name = "filename", .control = .{ .readonly = {} } };
        ui[1] = .{ .name = "wb_mode", .control = .{ .combo = .{ .items = &.{ "cam_mul", "pre_mul" } } } };
        break :init ui;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "output",
            .type = .source,
            .format = .rggb16uint,
            .roi = null,
            // the raw output is in the camera's color space, WB unknown/as-shot
            .color_profile = .{ .white_point = .any, .primaries = .camera },
        };
        break :init s;
    },
    .initParams = initParams,
    .init = init,
    .deinit = deinit,
    .modifyOut = modifyOut,
    .createNodes = createNodes,
    .readSource = readSource,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, pipe: api.PipelineHandle, mod_handle: api.ModuleHandle) !void {
    var raw_image = try allocator.create(RawImage);
    errdefer raw_image.deinit();

    const filename = try api.getParam(pipe, mod_handle, "filename", []const u8);
    slog.info("i-raw Filename param value: {s}", .{filename});

    raw_image.* = try RawImage.read(allocator, io, filename);
    errdefer raw_image.deinit();

    var mod = try api.getModule(pipe, mod_handle);
    mod.desc.data = raw_image;
}

pub fn deinit(allocator: std.mem.Allocator, pipe: api.PipelineHandle, mod: api.ModuleHandle) void {
    const m = api.getModule(pipe, mod) catch return;
    const data_ptr = m.desc.data orelse return;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    raw_image.deinit();
    allocator.destroy(raw_image);
}

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "filename", @as([]const u8, "input.raw"));
    try api.initParamNamed(pipe, mod, "wb_mode", @backingInt(WbMode.pre_mul));
}

fn computeCamToSrgb(raw_image: *RawImage) [3][3]f32 {
    const srgb_from_xyz: [3][3]f32 = .{
        .{ 3.2409699, -1.5373832, -0.49861076 },
        .{ -0.96924365, 1.8759675, 0.04155506 },
        .{ 0.05563008, -0.20397696, 1.0569715 },
    };
    const xyz_from_srgb = api.math.mat3.inv(f32, srgb_from_xyz);

    //   raw_image.cam_xyz is CAM<-XYZ.
    // Convert that into CAM<-sRGB first, normalize each camera row,
    // then invert to obtain sRGB<-CAM.
    var cam_from_srgb: [3][3]f32 = @splat(@splat(0.0));
    api.math.mat3x3Mul(&cam_from_srgb, raw_image.cam_xyz, xyz_from_srgb);
    return api.math.mat3.inv(f32, cam_from_srgb);
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
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    const wb_mode: WbMode = @fromBackingInt(@intCast(try api.getParam(pipe, mod, "wb_mode", i32)));

    const roi: api.ROI = .{
        .w = @intCast(raw_image.width),
        .h = @intCast(raw_image.height),
    };
    // NOTE: single-channel rggb storage (one photosite per texel), so the
    // ROI is the true photosite dimensions of the sensor.

    const selected_wb_raw = switch (wb_mode) {
        .cam_mul => raw_image.cam_mul,
        .pre_mul => raw_image.pre_mul,
    };
    const selected_wb = normalizeWhiteBalance(selected_wb_raw);

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

    // LibRaw exposes cam_xyz as CAM<-XYZ. Store the actual inverse here so the
    // ImgParam field name matches its contents: XYZ<-CAM.
    const xyz_d65_from_cam = api.math.mat3.inv(f32, raw_image.cam_xyz);

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
        .srgb_from_cam = computeCamToSrgb(raw_image),
        .xyz_d65_from_cam = xyz_d65_from_cam,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(pipe.io, &stdout_buffer);
    const stdout = &writer.interface;
    // try raw_image.print(stdout);
    try m.img_param.?.print(stdout);
    try stdout.flush();

    var socket = try api.getModSocket(pipe, mod, "output");
    socket.roi = roi;
}

pub fn readSource(pipe: api.PipelineHandle, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    const m = try api.getModule(pipe, mod);
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));

    // copy the raw photosite data into the padded upload buffer row by row.
    // wgpu requires bytesPerRow aligned to 256; the upload region was sized
    // with that padding, so stride past the padding each row.
    const w = raw_image.width;
    const bytes_per_row = w * @sizeOf(u16);
    const aligned_bytes_per_row = ((bytes_per_row + 256 - 1) / 256) * 256;
    const upload_ptr: [*]u8 = @ptrCast(@alignCast(mapped));
    const src: [*]const u8 = @ptrCast(raw_image.raw_image.ptr);
    for (0..raw_image.height) |row| {
        @memcpy(upload_ptr[row * aligned_bytes_per_row ..][0..bytes_per_row], src[row * bytes_per_row ..][0..bytes_per_row]);
    }
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const same_as_mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNodeDesc(
        pipe,
        mod,
        .{
            .type = .source,
            .name = "source",
            .run_size = null,
            .sockets = init: {
                var s: api.Sockets = @splat(null);
                s[0] = same_as_mod_output_sock.*;
                break :init s;
            },
        },
    );
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
