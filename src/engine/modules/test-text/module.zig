const api = @import("../api.zig");
const std = @import("std");
const slog = std.log.scoped(.crop);

pub const def: api.ModuleDef = .{
    .desc = .{
        .name = "test-text",
        .type = .compute,
        .params_ui = &.{},
        .params = &.{
            .{ .name = "value", .len = 1, .typ = .f32 },
        },
        .sockets = &.{
            .{
                .name = "input",
                .access = .read,
                .resource = .rgba, .datatype = .f16,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .rgba, .datatype = .f16,
            },
        },
    },
    .initParams = initParams,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParam(pipe, mod, "value", @as(f32, 0.0));
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./text.wgsl") } },
        .name = "text",
        .sockets = &.{
            .{
                .name = "input",
                .access = .read,
                .resource = .rgba, .datatype = .f16,
            },
            .{
                .name = "output",
                .access = .write,
                .resource = .rgba, .datatype = .f16,
            },
        },
    });
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
