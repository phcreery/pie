const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "whitebalance",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb32float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rggb32float,
            .roi = null,
        };
        break :init s;
    },
    .createNodes = createNodes,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_whitebalance = try api.addNodeDesc(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = @embedFile("./whitebalance.wgsl") },
        .name = "whitebalance",
        .run_size = mod_output_sock.roi.?,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rggb32float,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rggb32float,
                .roi = mod_output_sock.roi,
            };
            break :init s;
        },
    });
    try api.inheritSocket(pipe, mod, "input", node_whitebalance, "input");
    try api.inheritSocket(pipe, mod, "output", node_whitebalance, "output");
}
