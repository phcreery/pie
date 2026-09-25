const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "whitebalance",
    .type = .compute,
    .params = &.{},
    .params_ui = &.{},
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
    .createNodes = createNodes,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_whitebalance = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./whitebalance.wgsl") } },
        .name = "whitebalance",
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
    try api.setNodeRunSize(pipe, node_whitebalance, mod_output_sock.roi);
    try api.inheritSocket(pipe, mod, "input", node_whitebalance, "input");
    try api.inheritSocket(pipe, mod, "output", node_whitebalance, "output");
}
