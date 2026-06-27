const api = @import("../api.zig");
const std = @import("std");

pub var desc: api.ModuleDesc = .{
    .name = "test-nop-zig",
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
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyROIOut = null,
};

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {

    // const compute_spv = @embedFile("./compute.spv");
    // std.debug.print("compute.spv size: {any}\n", .{compute_spv.len});
    // std.debug.print("compute.spv first 16 bytes: ", .{});
    // for (compute_spv[0..8]) |b| {
    //     std.debug.print("{x} ", .{b});
    // }

    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = @embedFile("./compute.spv"),
        .temp_shader_language = .spirv, // TODO: remove this once we have a proper shader compilation pipeline
        .name = "test-nop-zig",
        .run_size = mod_output_sock.roi,
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
    };
    const node = try pipe.addNode(mod, node_desc);
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
