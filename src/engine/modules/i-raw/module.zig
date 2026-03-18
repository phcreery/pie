const std = @import("std");
const slog = std.log.scoped(.@"i-raw");
const RawImage = @import("libraw_image.zig").RawImage;

const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "i-raw",
    .type = .source,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "filename", .len = 256, .typ = .str };
        break :init p;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "output",
            .type = .source,
            .format = .rggb16uint,
            .roi = null,
        };
        break :init s;
    },
    .initParams = initParams,
    .init = init,
    .deinit = deinit,
    .modifyROIOut = modifyROIOut,
    .createNodes = createNodes,
    .readSource = readSource,
};

pub fn init(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod_handle: api.ModuleHandle) !void {
    var raw_image = try allocator.create(RawImage);
    errdefer raw_image.deinit();

    const filename = try api.getParam(pipe, mod_handle, "filename", []const u8);
    slog.info("i-raw Filename param value: {s}", .{filename});

    const file = try std.fs.cwd().openFile(filename, .{});
    raw_image.* = try RawImage.read(allocator, file);
    errdefer raw_image.deinit();

    var mod = try api.getModule(pipe, mod_handle);
    mod.desc.data = raw_image;
}

pub fn deinit(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod: api.ModuleHandle) void {
    const m = api.getModule(pipe, mod) catch return;
    const data_ptr = m.desc.data orelse return;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    raw_image.deinit();
    allocator.destroy(raw_image);
}

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "filename", @as([]const u8, "input.raw"));
}

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    var roi: api.ROI = .{
        .w = @intCast(raw_image.width),
        .h = @intCast(raw_image.height),
    };

    // THIS IS A WORKAROUND: for single channel read-write storage texture limitation
    roi = roi.div(4, 1); // we have 1/4 width input (packed RG/GB)

    // XYZ D65 to Rec709
    // #define matrix_xyz_to_rec709 makemat(3.24096994190452348, -1.53738317757009435, -0.498610760293003552, -0.969243636280879506, 1.87596750150771996, 0.0415550574071755843, 0.0556300796969936354, -0.20397695888897649, 1.05697151424287816)
    // const xyz_to_rec709: [3][3]f32 = .{
    //     .{ 3.24096994190452348, -1.53738317757009435, -0.498610760293003552 },
    //     .{ -0.969243636280879506, 1.87596750150771996, 0.0415550574071755843 },
    //     .{ 0.0556300796969936354, -0.20397695888897649, 1.05697151424287816 },
    // };
    // XYZ D65 to Rec2020
    // const xyz_to_rec2020: [3][3]f32 = .{
    //     .{ 1.7166511880, -0.3556707838, -0.2533662814 },
    //     .{ -0.6666843518, 1.6164812366, 0.0157685458 },
    //     .{ 0.0176398574, -0.0427706133, 0.9421031212 },
    // };

    // var cam_to_rec2020: [3][3]f32 = undefined;
    // api.mat3x3Mul(&cam_to_rec2020, xyz_to_rec2020, raw_image.cam_xyz);
    // api.mat3x3Mul(&cam_to_rec2020, xyz_to_rec709, raw_image.cam_xyz);

    // multiply wb by cam_to_rgb to get the white balance coefficients in the sRGB space (this is a bit of a hack, ideally we should do this in the shader, but it requires an extra matrix multiplication there which is a bit expensive)
    // perform matrix-vector multiplication
    // cam_t_rgb * wb
    // where cam_to_rgb is nxn [3][3]f32 and wb is nx1 [3]f32
    var wb_srgb: [3]f32 = undefined;
    for (raw_image.white_balance[0..3], 0..) |wb_val, i| {
        var sum: f32 = 0.0;
        for (raw_image.cam_to_srgb[i][0..3]) |cam_to_rgb_val| {
            sum += cam_to_rgb_val / wb_val;
        }
        wb_srgb[i] = sum;
    }

    wb_srgb[0] /= wb_srgb[1];
    wb_srgb[2] /= wb_srgb[1];
    wb_srgb[1] = 1.0;

    wb_srgb[0] = 1.0 / wb_srgb[0];
    wb_srgb[1] = 1.0;
    wb_srgb[2] = 1.0 / wb_srgb[2];

    // add a zero to the end to make it a vec4 for the shader
    // const wb_srgb_vec4 = [4]f32{ wb_srgb[0], wb_srgb[1], wb_srgb[2], 0.0 };

    std.debug.print("i-raw module: wb_srgb:\n", .{});
    std.debug.print("{d}, {d}, {d}\n", .{ wb_srgb[0], wb_srgb[1], wb_srgb[2] });

    // print cam_to_rgb_val
    std.debug.print("i-raw module: cam_to_srgb:\n", .{});
    for (raw_image.cam_to_srgb) |row| {
        std.debug.print("{d}, {d}, {d}\n", .{ row[0], row[1], row[2] });
    }

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

    const wb_srgb_vec4 = [4]f32{ wb_srgb[0], wb_srgb[1], wb_srgb[2], 1.0 };

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
        .white_balance = wb_srgb_vec4,
        // .white_balance = wb_srgb_vec4,
        .orientation = orientation,
        // .cam_to_rec2020 = cam_to_rec2020,
        .cam_to_srgb = raw_image.cam_to_srgb,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try raw_image.print(stdout);
    try m.img_param.?.print(stdout);
    try stdout.flush(); // Don't forget to flush!

    var socket = try api.getModSocket(pipe, mod, "output");
    socket.roi = roi;
}

pub fn readSource(pipe: *api.Pipeline, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    const m = try api.getModule(pipe, mod);
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));

    const upload_buffer_ptr: [*]u16 = @ptrCast(@alignCast(mapped));
    @memcpy(upload_buffer_ptr, raw_image.raw_image);
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const same_as_mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNode(
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
    try api.copyConnector(pipe, mod, "output", node, "output");
}
