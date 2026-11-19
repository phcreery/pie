const api = @import("../api.zig");

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "denoise",
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
                .resource = .rggb, .datatype = .f32,
                .color_profile = .any,
            },
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
    try api.setNodeRunSize(pipe, node_interpolation, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node_interpolation, "input");
    try api.inheritSocket(pipe, mod, "output", node_interpolation, "output");
}
