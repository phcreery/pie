const std = @import("std");
const pie = @import("pie");
const console = @import("console");

const gpu = pie.gpu;
const Pipeline = pie.Pipeline;

test "format lookup is extension-driven" {
    try std.testing.expect(pie.graphs.formatForPath("a.jpg") == null);
    try std.testing.expectEqualStrings("i-raw", pie.graphs.formatForPath("a.NEF").?.source_module);
    try std.testing.expectEqualStrings("i-png", pie.graphs.formatForPath("a.PNG").?.source_module);
}

// Regression: rerouting reallocates every module's upload staging from a
// fixed-size buffer. Opening images in a loop rebuilds the editor graph, so a
// missing allocator reset used to exhaust the buffer after a couple of files
// (the reported "pipeline re-run failed: OutOfMemory").
test "repeated reroutes do not exhaust the staging buffer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cp_out = console.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    // default buffers (75 MB): a 46 MB PNG upload fits once, so the leak would
    // fail on the second reroute
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, .{});
    defer pipeline.deinit();

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        pipeline.clear();
        _ = try pie.graphs.recommend(&pipeline, "testing/images/DSC_6765_debayered.png", .{});
        try pipeline.run();
    }
}

// The graph the thumbnail cache builds: the recommended decode for the file
// type, capped by `downscale` and written through `o-qoi`. Exercises the QOI
// sink and the format-agnostic lookup the cache dispatches on.
test "qoi thumbnail graph round-trips a solid image" {
    const zigimg = @import("zigimg");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cp_out = console.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "in.png" });
    defer allocator.free(in_path);
    const out_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "out.qoi" });
    defer allocator.free(out_path);

    // 4x4 solid green source
    const green: [64]u8 = blk: {
        var g: [64]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 4) {
            g[i] = 0;
            g[i + 1] = 255;
            g[i + 2] = 0;
            g[i + 3] = 255;
        }
        break :blk g;
    };
    var src = try zigimg.Image.fromRawPixels(allocator, 4, 4, &green, .rgba32);
    defer src.deinit(allocator);
    var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try src.writeToFilePath(allocator, io, in_path, write_buffer[0..], .{ .png = .{} });

    var gpu_instance = try gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, .{
        .upload_buffer_size_bytes = 8 * 1024 * 1024,
        .download_buffer_size_bytes = 8 * 1024 * 1024,
    });
    defer pipeline.deinit();

    const format = pie.graphs.formatForPath(in_path).?;
    const graph = try pie.graphs.recommendFormat(&pipeline, format, .{
        .max_edge = 1,
        .output_path = out_path,
        .output_module = "o-qoi",
    });
    try pipeline.setModuleParam(graph.source, "filename", []const u8, in_path);
    try pipeline.run();

    const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, out_path, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "qoif"));

    var out = try zigimg.Image.fromMemory(allocator, bytes);
    defer out.deinit(allocator);
    try out.convert(allocator, .rgba32);

    try std.testing.expectEqual(@as(u32, 1), out.width);
    try std.testing.expectEqual(@as(u32, 1), out.height);
    const px = out.pixels.rgba32;
    try std.testing.expect(px[0].r < 5); // red ~0
    try std.testing.expect(px[0].g > 250); // green ~255
    try std.testing.expect(px[0].b < 5); // blue ~0
    try std.testing.expect(px[0].a > 250); // alpha ~255
}
