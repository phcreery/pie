const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "whitebalance",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb16float,
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
    const node_whitebalance = try pipe.addNode(mod, .{
        .type = .compute,
        .shader = @embedFile("./whitebalance.wgsl"),
        .name = "whitebalance",
        .run_size = mod_output_sock.roi.?,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rggb16float,
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
    });
    try pipe.copyConnector(mod, "input", node_whitebalance, "input");
    try pipe.copyConnector(mod, "output", node_whitebalance, "output");
}
