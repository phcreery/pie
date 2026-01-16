const api = @import("../api.zig");

pub var module: api.ModuleDesc = .{
    .name = "test-2nodes",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.Param = @splat(null);
        p[0] = .{ .name = "value", .value = .{ .i32 = 1 } };
        break :init p;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyROIOut = null,
};

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_add_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = @embedFile("add.wgsl"),
        .name = "add",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
                .roi = null, // populated with api.copyConnector()
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = mod_output_sock.roi, // we are responsible for setting this correctly
            };
            break :init s;
        },
    };
    const node_add = try pipe.addNode(mod, node_add_desc);
    const node_sub_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = @embedFile("sub.wgsl"),
        .name = "sub",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
                .roi = mod_output_sock.roi, // we are responsible for setting this correctly
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = null, // populated with api.copyConnector()
            };
            break :init s;
        },
    };
    const node_sub = try pipe.addNode(mod, node_sub_desc);

    try pipe.copyConnector(mod, "input", node_add, "input");
    try pipe.connectNodesName(node_add, "output", node_sub, "input");
    try pipe.copyConnector(mod, "output", node_sub, "output");
}
