const std = @import("std");
const pie = @import("pie");

// The default graphs live in `assets/` and are compiled in, so nothing at
// runtime would notice one being hand-edited into something the engine does not
// understand (serdes skips unknown lines with a warning). This pins each asset
// to the copy the build embedded and to exactly what the serializer emits for
// that family's pipeline.
test "default graph assets are what the serializer produces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const probes = [_]struct { path: []const u8, asset: []const u8 }{
        .{ .path = "photo.nef", .asset = "assets/default.i-raw.graph" },
        .{ .path = "photo.png", .asset = "assets/default.i-png.graph" },
    };

    for (probes) |probe| {
        const format = pie.graphs.formatForPath(probe.path).?;

        const on_disk = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, probe.asset, allocator, .unlimited);
        defer allocator.free(on_disk);
        try std.testing.expectEqualStrings(on_disk, format.graph);

        var pipeline = try pie.Pipeline.init(allocator, io, null, null);
        defer pipeline.deinit();
        _ = try pie.graphs.recommendFormat(&pipeline, format, .{});

        var w = std.Io.Writer.Allocating.init(allocator);
        defer w.deinit();
        try pie.serdes.serialize(&pipeline, &w.writer);
        try std.testing.expectEqualStrings(format.graph, w.written());
    }
}

// `Options` rewrites the asset's tail rather than being baked into it: the
// display sink becomes the requested file sink, and `max_edge` slots a
// downscale in front of it.
test "options rewrite the graph's tail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const format = pie.graphs.formatForPath("photo.nef").?;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "thumb.qoi" });
    defer allocator.free(out_path);

    var pipeline = try pie.Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();

    const graph = try pie.graphs.recommendFormat(&pipeline, format, .{
        .max_edge = 256,
        .output_path = out_path,
        .output_module = "o-qoi",
    });

    const source = try pipeline.module_pool.getPtr(graph.source);
    try std.testing.expectEqualStrings("i-raw", source.name);
    // the asset's display sink is replaced, not kept alongside the file sink
    try std.testing.expect(!pipeline.module_name_map.contains("o-display:01"));

    const sink = try pipeline.module_pool.getPtr(graph.sink);
    try std.testing.expectEqualStrings("o-qoi", sink.name);
    try std.testing.expectEqualStrings(out_path, (try sink.getParamPtr("filename")).get([]const u8));

    // ... filmcurv -> downscale -> sink
    const downscale_handle = sink.sockets[0].?.connected_to_module.?;
    const downscale = try pipeline.module_pool.getPtr(downscale_handle.item);
    try std.testing.expectEqualStrings("downscale", downscale.name);
    try std.testing.expectEqual(@as(i32, 256), (try downscale.getParamPtr("max_edge")).get(i32));

    const upstream_handle = downscale.sockets[0].?.connected_to_module.?;
    const upstream = try pipeline.module_pool.getPtr(upstream_handle.item);
    try std.testing.expectEqualStrings("filmcurv", upstream.name);
}
