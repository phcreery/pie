const std = @import("std");
const pie = @import("pie");
const console = @import("console");

const gpu = pie.gpu;
const Pipeline = pie.Pipeline;

// The recommended PNG graph is `i-png -> format -> downscale -> o-display`;
// this proves the whole chain runs and the downscale caps the longest edge.
test "png through the recommended pipeline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cp_out = console.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 96 * 1024 * 1024,
        .download_buffer_size_bytes = 8 * 1024 * 1024,
    };

    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, pipeline_config);
    defer pipeline.deinit();

    _ = try pie.graphs.recommend(
        &pipeline,
        "testing/images/DSC_6765_debayered.png",
        .{ .max_edge = 256 },
    );

    try pipeline.run();

    const texture = try pipeline.getDisplaySinkTexture();
    // 3008x2008 PNG, longest edge capped at 256, aspect preserved
    try std.testing.expectEqual(@as(u32, 256), texture.roi.w);
    try std.testing.expectEqual(@as(u32, 170), texture.roi.h);
}

test "format lookup is extension-driven" {
    try std.testing.expect(pie.graphs.formatForPath("a.jpg") == null);
    try std.testing.expectEqualStrings("i-raw", pie.graphs.formatForPath("a.NEF").?.source_module);
    try std.testing.expectEqualStrings("i-png", pie.graphs.formatForPath("a.PNG").?.source_module);
}

// End-to-end correctness: a solid-colour PNG decoded by i-png, box-averaged by
// downscale and re-encoded by o-png must come out as the same solid colour at
// the reduced size. Exercises decode, the downscale math and encode together.
test "downscale box-averages a solid image" {
    const zigimg = @import("zigimg");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cp_out = console.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "in.png" });
    defer allocator.free(in_path);
    const out_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "out.png" });
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

    const src_mod = try pipeline.addModule("01", "i-png");
    const fmt_mod = try pipeline.addModule("01", "format");
    const ds_mod = try pipeline.addModule("01", "downscale");
    const out_mod = try pipeline.addModule("01", "o-png");
    try pipeline.setModuleParam(src_mod, "filename", []const u8, in_path);
    try pipeline.setModuleParam(ds_mod, "max_edge", i32, 1);
    try pipeline.setModuleParam(out_mod, "filename", []const u8, out_path);
    try pipeline.connectModules(src_mod, "output", fmt_mod, "input");
    try pipeline.connectModules(fmt_mod, "output", ds_mod, "input");
    try pipeline.connectModules(ds_mod, "output", out_mod, "input");

    try pipeline.run();

    const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, out_path, allocator, .unlimited);
    defer allocator.free(bytes);
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

// Compares the two PNG decoders on this 16-bit file: zigimg (a Zig module,
// compiled at this artifact's optimize) against stb_image (an optimized C
// library). The i-png module uses the latter.
test "benchmark png decode paths" {
    const zigimg = @import("zigimg");
    const stbi = @import("stbi");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "testing/images/DSC_6765_debayered.png";

    const ns_per_ms = std.time.ns_per_ms;

    const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    {
        const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);
        defer allocator.free(bytes);
        var img = try zigimg.Image.fromMemory(allocator, bytes);
        defer img.deinit(allocator);
        try img.convert(allocator, .rgba32);
        const rgba = std.mem.sliceAsBytes(img.pixels.rgba32);
        const converted = try allocator.alloc(f16, rgba.len);
        defer allocator.free(converted);
        for (rgba, 0..) |sample, i| converted[i] = @as(f16, @floatFromInt(sample)) / 255.0;
    }
    const t1 = std.Io.Timestamp.now(io, .awake).nanoseconds;

    {
        var image = try stbi.decode16(allocator, path, 4);
        defer image.deinit(allocator);
    }
    const t2 = std.Io.Timestamp.now(io, .awake).nanoseconds;

    std.debug.print("png decode (Debug): zigimg={d}ms stb_image={d}ms\n", .{
        @divTrunc(t1 - t0, ns_per_ms),
        @divTrunc(t2 - t1, ns_per_ms),
    });
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
