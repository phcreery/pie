const api = @import("../api.zig");
const std = @import("std");

pub const module: api.ModuleDesc = .{
    .name = "test-o-2468",
    .type = .sink,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .sink,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = writeSink,
    .createNodes = createNodes,
    .modifyROIOut = null,
};

const expected = [_]f16{ 2.0, 4.0, 6.0, 8.0 };

pub fn writeSink(
    pipe: *api.Pipeline,
    mod: api.ModuleHandle,
    mapped: *anyopaque,
) !void {
    const sock = api.getModSocket(pipe, mod, "input") orelse unreachable;
    const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    const download_buffer_slice = download_buffer_ptr[0..(sock.roi.?.w * sock.roi.?.h * sock.format.nchannels())];
    std.debug.print("Downloaded buffer: {any}\n", .{download_buffer_slice});
    try std.testing.expectEqualSlices(f16, &expected, download_buffer_slice);
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const same_as_mod_output_sock = api.getModSocket(pipe, mod, "input") orelse unreachable;
    const node_desc: api.NodeDesc = .{
        .type = .sink,
        .shader_code = "",
        .entry_point = "Sink",
        .run_size = null,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = same_as_mod_output_sock.*;
            break :init s;
        },
    };
    const node = try pipe.addNode(mod, node_desc);
    try pipe.copyConnector(mod, "input", node, "input");
}
