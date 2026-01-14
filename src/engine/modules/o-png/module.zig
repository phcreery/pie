const api = @import("../api.zig");
const std = @import("std");
const zigimg = @import("zigimg");

pub const module: api.ModuleDesc = .{
    .name = "o-png",
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
    .writeSink = writeSink,
    .createNodes = createNodes,
};

pub fn writeSink(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    // const m = try api.getModule(pipe, mod);
    const socket = try api.getModSocket(pipe, mod, "input");

    const sock = try api.getModSocket(pipe, mod, "input");
    const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    const download_buffer_slice = download_buffer_ptr[0..(sock.roi.?.w * sock.roi.?.h * sock.format.nchannels())];
    // std.debug.print("Downloaded buffer: {any}\n", .{download_buffer_slice});

    // EXPORT PNG
    {
        // convert f16 slice to f32 slice
        std.log.info("Casting f16 to f32", .{});
        const output_slice = try allocator.alloc(f32, download_buffer_slice.len);
        defer allocator.free(output_slice);
        for (download_buffer_slice, 0..) |value, i| {
            output_slice[i] = @as(f32, value);
        }

        std.log.info("Casting to bytes", .{});
        const byte_array2 = std.mem.sliceAsBytes(output_slice);

        std.log.info("Giving to zigimg", .{});
        var zig_image = try zigimg.Image.fromRawPixels(allocator, socket.roi.?.w, socket.roi.?.h, byte_array2[0..], .float32);
        defer zig_image.deinit(allocator);

        try zig_image.convert(allocator, .rgba64);
        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zig_image.writeToFilePath(allocator, "testing/integration/fullsize/DSC_6765_debayered.png", write_buffer2[0..], .{ .png = .{} });
    }
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
