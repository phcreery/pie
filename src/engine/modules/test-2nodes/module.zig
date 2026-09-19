const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "test-2nodes",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "value", .len = 1, .typ = .i32 };
        break :init p;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
        };
        break :init s;
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
    const node_add_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = .{ .wgsl = @embedFile("./add.wgsl") },
        .name = "add",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
            };
            break :init s;
        },
    };
    const node_add = try api.addNode(pipe, mod, node_add_desc);
    try api.setNodeSocketRoi(pipe, node_add, "output", mod_output_sock.roi);
    const node_sub_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = .{ .wgsl = @embedFile("sub.wgsl") },
        .name = "sub",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
            };
            break :init s;
        },
    };
    const node_sub = try api.addNode(pipe, mod, node_sub_desc);
    try api.setNodeSocketRoi(pipe, node_sub, "input", mod_output_sock.roi);

    try api.inheritSocket(pipe, mod, "input", node_add, "input");
    try api.connectNodesByName(pipe, node_add, "output", node_sub, "input");
    try api.inheritSocket(pipe, mod, "output", node_sub, "output");
}
