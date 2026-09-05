const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "denoise",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb16float,
            .roi = null,
            .color_profile = .any,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rggb16float,
            .roi = null,
            .color_profile = .any,
        };
        break :init s;
    },
    .createNodes = createNodes,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_interpolation = try api.addNodeDesc(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = @embedFile("./interpolation.wgsl") },
        .name = "interpolation",
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
    try api.inheritSocket(pipe, mod, "input", node_interpolation, "input");
    try api.inheritSocket(pipe, mod, "output", node_interpolation, "output");
}
