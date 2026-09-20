const api = @import("../api.zig");
const std = @import("std");

pub const desc: api.ModuleDesc = .{
    .name = "demosaic",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb32float,
            .color_profile = .any,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .color_profile = .any,
        };
        break :init s;
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
        .shader = .{ .wgsl = .{ .embed = @embedFile("./halfsize.wgsl") } },
        .name = "halfsize",
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rggb32float,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
            };
            break :init s;
        },
    });
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
