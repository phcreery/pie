//! `o-qoi` sink: writes the sink's pixels as a Quite OK Image.

const api = @import("../api.zig");
const std = @import("std");
const zigimg = @import("zigimg");

pub const desc: api.ModuleDesc = .{
    .name = "o-qoi",
    .type = .sink,
    .params_ui = &.{},
    .params = &.{
        .{ .name = "filename", .len = 256, .typ = .str },
    },
    .sockets = &.{
        .{
            .name = "input",
            .type = .sink,
            .format = .rgba16float,
            .color_profile = .any,
        },
    },
    .initParams = initParams,
    .writeSink = writeSink,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "filename", @as([]const u8, "output.qoi"));
}

pub fn writeSink(allocator: std.mem.Allocator, io: std.Io, pipe: api.PipelineHandle, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    const socket = try api.getModSocket(pipe, mod, "input");
    const roi = socket.roi.?;
    const filename = try api.getParam(pipe, mod, "filename", []const u8);

    // The sink socket is f16 RGBA in [0,1] and QOI stores 8-bit RGBA. Scale here
    // rather than through the float32 pixel format, whose rgba32 conversion
    // truncates instead of clamping and so traps on samples above white.
    const samples: [*]const f16 = @ptrCast(@alignCast(mapped));
    const rgba = try allocator.alloc(u8, roi.w * roi.h * socket.format.nchannels());
    defer allocator.free(rgba);
    for (samples[0..rgba.len], rgba) |sample, *byte| {
        byte.* = @intFromFloat(std.math.clamp(@as(f32, sample), 0.0, 1.0) * 255.0 + 0.5);
    }

    var image = try zigimg.Image.fromRawPixels(allocator, roi.w, roi.h, rgba, .rgba32);
    defer image.deinit(allocator);

    var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try image.writeToFilePath(allocator, io, filename, write_buffer[0..], .{ .qoi = .{} });
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
