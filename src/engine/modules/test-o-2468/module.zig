const api = @import("../api.zig");
const std = @import("std");

pub const desc: api.ModuleDesc = .{
    .name = "test-o-2468",
    .type = .sink,
    .params = &.{},
    .params_ui = &.{},
    .sockets = &.{
        .{
            .name = "input",
            .type = .sink,
            .format = .rgba16float,
        },
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = writeSink,
    .createNodes = createNodes,
    .modifyOut = null,
};

const expected = [_]f16{ 2.0, 4.0, 6.0, 8.0 };

pub fn writeSink(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipe: api.PipelineHandle,
    mod: api.ModuleHandle,
    mapped: *anyopaque,
) !void {
    _ = allocator;
    _ = io;
    const sock = try api.getModSocket(pipe, mod, "input");
    const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    const download_buffer_slice = download_buffer_ptr[0..(sock.roi.?.w * sock.roi.?.h * sock.format.nchannels())];
    std.debug.print("Downloaded buffer: {any}\n", .{download_buffer_slice});
    try std.testing.expectEqualSlices(f16, &expected, download_buffer_slice);
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const node = try api.addNode(pipe, mod, .{
        .type = .sink,
        .name = "sink",
        .sockets = &.{
            try api.copyModSocket(desc, "input"),
        },
    });
    try api.inheritSocket(pipe, mod, "input", node, "input");
}
