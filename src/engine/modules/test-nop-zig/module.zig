const api = @import("../api.zig");
const std = @import("std");

pub const desc: api.ModuleDesc = .{
    .name = "test-nop-zig",
    .type = .compute,
    .params = &.{},
    .params_ui = &.{},
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
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyOut = null,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    const node = try api.addNode(pipe, mod, @import("nop.comp.zon"));
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi);

    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
