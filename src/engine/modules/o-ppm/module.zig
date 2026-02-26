const api = @import("../api.zig");
const std = @import("std");
const zigimg = @import("zigimg");

pub const desc: api.ModuleDesc = .{
    .name = "o-ppm",
    .type = .sink,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "filename", .len = 256, .typ = .str };
        break :init p;
    },
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
    .initParams = initParams,
    .createNodes = createNodes,
    .writeSink = writeSink,
};

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "filename", @as([]const u8, "output.ppm"));
}

pub fn writeSink(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    const socket = try api.getModSocket(pipe, mod, "input");

    const filename = try api.getParam(pipe, mod, "filename", []const u8);
    std.log.info("Filename param value: {s}", .{filename});

    const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    const download_buffer_slice = download_buffer_ptr[0..(socket.roi.?.w * socket.roi.?.h * socket.format.nchannels())];

    // EXPORT PPM
    {
        // convert f16 slice to f32 slice
        const output_slice = try allocator.alloc(f32, download_buffer_slice.len);
        defer allocator.free(output_slice);
        for (download_buffer_slice, 0..) |value, i| {
            output_slice[i] = @as(f32, value);
        }

        const byte_array2 = std.mem.sliceAsBytes(output_slice);

        var zig_image = try zigimg.Image.fromRawPixels(allocator, socket.roi.?.w, socket.roi.?.h, byte_array2[0..], .float32);
        defer zig_image.deinit(allocator);

        try zig_image.convert(allocator, .rgb24);

        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zig_image.writeToFilePath(allocator, filename, write_buffer2[0..], .{ .ppm = .{} });
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
