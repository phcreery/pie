const api = @import("../api.zig");
const std = @import("std");

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "demosaic",
        .type = .compute,
        .params = &.{},
        .params_ui = &.{},
        .sockets = &.{
            .{
                .name = "input",
                .access = .read,
                .resource = .rggb, .datatype = .f32,
                .color_profile = .any,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .rgba, .datatype = .f16,
                .color_profile = .any,
            },
        },
    },
    .createNodes = createNodes,
    .modifyOut = modifyOut,
};

fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const input_sock = try api.getModSocket(pipe, mod, "input");
    var roi: api.ROI = input_sock.roi.?;
    // one output pixel per 2x2 bayer cell -> true half resolution
    const roi_half = roi.div(2, 2);
    var output_sock = try api.getModSocket(pipe, mod, "output");
    output_sock.roi = roi_half;
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./halfsize.wgsl") } },
        .name = "halfsize",
        .sockets = &.{
            .{
                .name = "input",
                .access = .read,
                .resource = .rggb, .datatype = .f32,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .rgba, .datatype = .f16,
            },
        },
    });
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
