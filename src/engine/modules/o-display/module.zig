const api = @import("../api.zig");
const std = @import("std");
const slog = std.log.scoped(.@"o-display");

pub const desc: api.ModuleDesc = .{
    .name = "o-display",
    .type = .sink,
    // .params = init: {
    //     var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
    //     p[0] = .{ .name = "filename", .len = 256, .typ = .str };
    //     break :init p;
    // },
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
    .createNodes = createNodes,
    .writeSink = writeSink,
};

pub fn writeSink(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipe: *api.Pipeline,
    mod: api.ModuleHandle,
    mapped: *anyopaque,
) !void {
    const socket = try api.getModSocket(pipe, mod, "input");
    _ = socket;
    _ = allocator;
    _ = io;
    _ = mapped;

    // const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    // const download_buffer_slice = download_buffer_ptr[0..(socket.roi.?.w * socket.roi.?.h * socket.format.nchannels())];

}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const same_as_mod_output_sock = try api.getModSocket(pipe, mod, "input");
    const node_desc: api.NodeDesc = .{
        .type = .sink,
        .name = "sink",
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
