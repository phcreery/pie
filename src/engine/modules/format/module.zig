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
            .color_profile = .any,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rggb32float,
            .roi = null,
            .color_profile = .any,
        };
        break :init s;
    },
    .createNodes = createNodes,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = .{ .wgsl = @embedFile("./format.wgsl") },
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
                .format = .rggb32float,
                .roi = mod_output_sock.roi,
            };
            break :init s;
        },
    };
    const node = try api.addNodeDesc(pipe, mod, node_desc);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
