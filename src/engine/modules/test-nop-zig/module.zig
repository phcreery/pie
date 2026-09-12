const api = @import("../api.zig");
const std = @import("std");

pub const desc: api.ModuleDesc = .{
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
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    var node_desc = api.parseNodeDescZon(@import("nop.comp.zon"));
    node_desc.run_size = mod_output_sock.roi;
    const node = try api.addNodeDesc(pipe, mod, node_desc);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
