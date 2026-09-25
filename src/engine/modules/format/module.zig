const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "format",
    .type = .compute,
    .params = &.{},
    .params_ui = &.{},
    .sockets = &.{
        .{
            .name = "input",
            .type = .read,
            .format = .rggb16uint,
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
    const node = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./format.wgsl") } },
        .name = "u16_to_f16",
        .sockets = &.{
            .{
                .name = "input",
                .type = .read,
                .format = .rggb16uint,
            },
            .{
                .name = "output",
                .type = .write,
                .format = .rggb32float,
            },
        },
    });
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
