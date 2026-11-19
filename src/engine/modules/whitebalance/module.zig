const api = @import("../api.zig");

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "whitebalance",
        .type = .compute,
        .params = &.{},
        .params_ui = &.{},
        .sockets = &.{
            .{
                .name = "input",
                .access = .read,
                .resource = .rggb, .datatype = .f32,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .rggb, .datatype = .f32,
            },
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
                .access = .read,
                .resource = .rggb, .datatype = .f32,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .rggb, .datatype = .f32,
            },
        },
    });
    try api.setNodeRunSize(pipe, node_whitebalance, mod_output_sock.roi);
    try api.inheritSocket(pipe, mod, "input", node_whitebalance, "input");
    try api.inheritSocket(pipe, mod, "output", node_whitebalance, "output");
}
