const api = @import("../api.zig");
const std = @import("std");
const slog = std.log.scoped(.crop);

pub const desc: api.ModuleDesc = .{
    .name = "crop",
    .type = .compute,
    .params = &.{
        .{ .name = "rotation", .len = 1, .typ = .f32 },
        .{ .name = "meta_rotation_deg", .len = 1, .typ = .f32 },
    },
    .params_ui = &.{
        .{ .name = "rotation", .control = .{ .slider = .{ .min = -180, .max = 180, .step = 0.5, .suffix = " deg" } } },
    },
    .sockets = &.{
        .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .color_profile = .any,
        },
        .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .color_profile = .any,
        },
    },
    .initParams = initParams,
    .modifyOut = modifyOut,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "rotation", @as(f32, 0.0));
    try api.initParamNamed(pipe, mod, "meta_rotation_deg", @as(f32, 0.0));
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
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

    const rotation_deg: f32 = switch (metadata_orientation) {
        .normal => 0.0,
        .rotate180 => 180.0,
        .rotate90CW => 90.0,
        .rotate270CW => 270.0,
    };
    try api.setParam(pipe, mod, "meta_rotation_deg", f32, rotation_deg);
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    const node = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./rotate_center.wgsl") } },
        .name = "rotate_center",
        .sockets = &.{
            .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
            },
            .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
            },
        },
    });
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
