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
    .modifyOut = null,
};

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {

    // const compute_spv = @embedFile("./compute.spv");
    const compute_spv = @embedFile("nop.comp.zig.embed");
    std.debug.print("nop.comp.zig size: {any}\n", .{compute_spv.len});
    std.debug.print("nop.comp.zig first 16 bytes: ", .{});
    for (compute_spv[0..16]) |b| {
        std.debug.print("{x} ", .{b});
    }
    std.debug.print("\n", .{});

    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = .{ .spirv = @embedFile("nop.comp.zig.embed") },
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
    const node = try api.addNodeDesc(pipe, mod, node_desc);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
