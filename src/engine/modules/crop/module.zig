const api = @import("../api.zig");
const std = @import("std");
const slog = std.log.scoped(.crop);

pub var desc: api.ModuleDesc = .{
    .name = "crop",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "rotation_deg", .len = 1, .typ = .f32 };
        break :init p;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
    },
    .initParams = initParams,
    .modifyROIOut = modifyROIOut,
    .createNodes = createNodes,
};

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "rotation_deg", @as(f32, 0.0));
}

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);
    const input_sock = try api.getModSocket(pipe, mod, "input");

    // handle orientation from image metadata (EXIF-style): 1 = normal, 3 = 180, 6 = 90 CW, 8 = 270 CW
    const metadata_orientation = m.*.img_param.?.orientation;

    // if orientation is 6 or 8, we need to swap width and height
    var roi = input_sock.roi orelse return error.ModuleROIMissing;
    if (metadata_orientation == .rotate90CW or metadata_orientation == .rotate270CW) {
        const tmp = roi.w;
        roi.w = roi.h;
        roi.h = tmp;
    }
    var output_sock = try api.getModSocket(pipe, mod, "output");
    output_sock.roi = roi;

    // set the rotation parameter based on the metadata orientation
    const rotation_deg: f32 = switch (metadata_orientation) {
        .normal => 0.0,
        .rotate180 => 180.0,
        .rotate90CW => 90.0,
        .rotate270CW => 270.0,
    };
    try api.setParam(pipe, mod, "rotation_deg", rotation_deg);
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    const node = try pipe.addNode(mod, .{
        .type = .compute,
        .shader = @embedFile("./crop.wgsl"),
        .name = "crop_rotate",
        .run_size = mod_output_sock.roi.?,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = null,
            };
            break :init s;
        },
    });
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
