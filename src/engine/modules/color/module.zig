const api = @import("../api.zig");

pub var module: api.ModuleDesc = .{
    .name = "color",
    .type = .compute,
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
    .createNodes = createNodes,
};

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_color = try pipe.addNode(mod, .{
        .type = .compute,
        .shader = @embedFile("./color.wgsl"),
        .name = "color",
        .run_size = mod_output_sock.roi.?,
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
                .roi = mod_output_sock.roi,
            };
            break :init s;
        },
    });
    try pipe.copyConnector(mod, "input", node_color, "input");
    try pipe.copyConnector(mod, "output", node_color, "output");
}
