const api = @import("../api.zig");
const std = @import("std");
const slog = std.log.scoped(.downscale);

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "downscale",
        .type = .compute,
        .params = &.{
            .{ .name = "max_edge", .len = 1, .typ = .i32 },
        },
        .params_ui = &.{
            .{ .name = "max_edge", .control = .{ .slider = .{ .min = 16, .max = 4096, .step = 1, .suffix = " px" } } },
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
    },
    .initParams = initParams,
    .modifyOut = modifyOut,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "max_edge", @as(i32, 256));
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const input = try api.getModSocket(pipe, mod, "input");
    const in_roi = input.roi orelse return error.ModuleROIMissing;

    const max_edge = try api.getParam(pipe, mod, "max_edge", i32);

    // preserve the input aspect ratio, scaling the longest edge down to
    // max_edge. integer math, mirroring the lighttable's downscaleFrom.
    var out = in_roi;
    if (max_edge > 0) {
        const longest = @max(in_roi.w, in_roi.h);
        const max_edge_u32: u32 = @intCast(max_edge);
        if (longest > max_edge_u32) {
            out.w = @max(1, in_roi.w * max_edge_u32 / longest);
            out.h = @max(1, in_roi.h * max_edge_u32 / longest);
        }
    }
    slog.debug("downscale {d}x{d} -> {d}x{d}", .{ in_roi.w, in_roi.h, out.w, out.h });

    const output = try api.getModSocket(pipe, mod, "output");
    output.roi = out;
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    const node = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./downscale.wgsl") } },
        .name = "downscale",
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
