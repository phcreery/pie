const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "denoise",
    .type = .compute,
    .params = &.{},
    .params_ui = &.{},
    .sockets = &.{
        .{
            .name = "input",
            .type = .read,
            .format = .rggb32float,
            .color_profile = .any,
        },
        .{
            .name = "output",
            .type = .write,
            .format = .rggb32float,
            .color_profile = .any,
        },
    },
    .createNodes = createNodes,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_interpolation = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./interpolation.wgsl") } },
        .name = "interpolation",
        .sockets = &.{
            .{
                .name = "input",
                .type = .read,
                .format = .rggb32float,
            },
            .{
                .name = "output",
                .type = .write,
                .format = .rggb32float,
            },
        },
    });
    try api.setNodeRunSize(pipe, node_interpolation, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node_interpolation, "input");
    try api.inheritSocket(pipe, mod, "output", node_interpolation, "output");
}
