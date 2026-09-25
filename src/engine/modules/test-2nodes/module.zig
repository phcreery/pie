const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "test-2nodes",
    .type = .compute,
    .params_ui = &.{},
    .params = &.{
        .{ .name = "value", .len = 1, .typ = .i32 },
    },
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
    .initParams = initParams,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyOut = null,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "value", @as(i32, 1.0));
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_add_desc: api.NodeDesc = comptime .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("./add.wgsl") } },
        .name = "add",
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
    };
    const node_add = try api.addNode(pipe, mod, node_add_desc);
    try api.setNodeSocketRoi(pipe, node_add, "output", mod_output_sock.roi);
    try api.setNodeRunSize(pipe, node_add, mod_output_sock.roi);
    const node_sub_desc: api.NodeDesc = comptime .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = @embedFile("sub.wgsl") } },
        .name = "sub",
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
    };
    const node_sub = try api.addNode(pipe, mod, node_sub_desc);
    try api.setNodeSocketRoi(pipe, node_sub, "input", mod_output_sock.roi);
    try api.setNodeRunSize(pipe, node_sub, mod_output_sock.roi);

    try api.inheritSocket(pipe, mod, "input", node_add, "input");
    try api.connectNodesByName(pipe, node_add, "output", node_sub, "input");
    try api.inheritSocket(pipe, mod, "output", node_sub, "output");
}
