const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "format",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb16uint,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rggb16float,
            .roi = null,
        };
        break :init s;
    },
    .createNodes = createNodes,
};

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = @embedFile("./format.wgsl"),
        .name = "u16_to_f16",
        .run_size = mod_output_sock.roi.?,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rggb16uint,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rggb16float,
                .roi = mod_output_sock.roi,
            };
            break :init s;
        },
    };
    const node = try pipe.addNode(mod, node_desc);
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
