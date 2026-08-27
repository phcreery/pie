const std = @import("std");
const pie = @import("pie");

const Pipeline = pie.Pipeline;
const Modules = pie.modules;

/// Darkroom-style chain: i-raw -> format -> denoise -> demosaic -> crop ->
/// color -> filmcurv -> o-display, all instances "01", with darkroom's exact
/// params set (several non-default). Uses the non-recording primitives so the
/// serdes round-trip exercises the raw pipeline (not the history).
fn buildChain(p: *Pipeline) !void {
    const iraw = try p.addModule("01", "i-raw");
    const format = try p.addModule("01", "format");
    const denoise = try p.addModule("01", "denoise");
    const demosaic = try p.addModule("01", "demosaic");
    const crop = try p.addModule("01", "crop");
    const color = try p.addModule("01", "color");
    const filmcurv = try p.addModule("01", "filmcurv");
    const odisplay = try p.addModule("01", "o-display");

    try p.setModuleParam(iraw, "filename", []const u8, "testing/images/DSC_6765.NEF");
    try p.setModuleParam(iraw, "wb_mode", i32, 0);

    try p.setModuleParam(color, "wb_tint", f32, 0.0);
    try p.setModuleParam(color, "wb_coeff", [3]f32, .{ 0.70393723, 1, 1.3611937 });

    try p.setModuleParam(filmcurv, "colormode", i32, 1);
    try p.setModuleParam(filmcurv, "brightness", f32, 3.8);
    try p.setModuleParam(filmcurv, "contrast", f32, 1.3);
    try p.setModuleParam(filmcurv, "bias", f32, 0.0);

    try p.connectModules(iraw, "output", format, "input");
    try p.connectModules(format, "output", denoise, "input");
    try p.connectModules(denoise, "output", demosaic, "input");
    try p.connectModules(demosaic, "output", crop, "input");
    try p.connectModules(crop, "output", color, "input");
    try p.connectModules(color, "output", filmcurv, "input");
    try p.connectModules(filmcurv, "output", odisplay, "input");
}

test "preset serialize emits vkdt-style lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var repository = try Modules.Repository.init(allocator);
    defer repository.deinit();

    var pipeline = try Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();
    try pipeline.addRepo(&repository);

    try buildChain(&pipeline);

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try pie.serdes.serialize(&pipeline, &w.writer);
    const text = w.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "module:i-raw:01\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connect:i-raw:01:output:format:01:input\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "param:i-raw:01:filename:testing/images/DSC_6765.NEF\n") != null);
    // never-initialized params are not serialized
    try std.testing.expect(std.mem.indexOf(u8, text, "param:i-raw:01:matrix_mode") == null);
}

test "preset round trip preserves pipeline state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var repository = try Modules.Repository.init(allocator);
    defer repository.deinit();

    var pipe_a = try Pipeline.init(allocator, io, null, null);
    defer pipe_a.deinit();
    try pipe_a.addRepo(&repository);
    try buildChain(&pipe_a);

    var w_a = std.Io.Writer.Allocating.init(allocator);
    defer w_a.deinit();
    try pie.serdes.serialize(&pipe_a, &w_a.writer);
    const text_a = w_a.written();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var pipe_b = try Pipeline.init(allocator, io, null, null);
    defer pipe_b.deinit();
    try pipe_b.addRepo(&repository);
    try pie.serdes.deserialize(&pipe_b, arena.allocator(), text_a);

    var w_b = std.Io.Writer.Allocating.init(allocator);
    defer w_b.deinit();
    try pie.serdes.serialize(&pipe_b, &w_b.writer);
    try std.testing.expectEqualStrings(text_a, w_b.written());

    // structural checks on the deserialized pipeline
    try std.testing.expectEqual(pipe_a.module_name_map.count(), pipe_b.module_name_map.count());

    const color_handle = pipe_b.module_name_map.get("color:01").?;
    const color_mod = try pipe_b.module_pool.getPtr(color_handle);
    const wb_coeff = (try color_mod.getParamPtr("wb_coeff")).get([3]f32);
    try std.testing.expectEqual(@as([3]f32, .{ 0.70393723, 1, 1.3611937 }), wb_coeff);

    const crop_handle = pipe_b.module_name_map.get("crop:01").?;
    const crop_mod = try pipe_b.module_pool.getPtr(crop_handle);
    const crop_conn = crop_mod.desc.sockets[0].?.private.connected_to_module.?;
    try std.testing.expectEqual(pipe_b.module_name_map.get("demosaic:01").?, crop_conn.item);
}

test "preset deserialize accepts vkdt syntax" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var repository = try Modules.Repository.init(allocator);
    defer repository.deinit();

    var pipeline = try Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();
    try pipeline.addRepo(&repository);

    const text =
        \\# a vkdt-style comment line
        \\module:format:01
        \\module:i-raw:main:100:200
        \\connect:i-raw:main:output:format:01:input
        \\param:i-raw:main:filename:path/with space.NEF
        \\module:format:01
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try pie.serdes.deserialize(&pipeline, arena.allocator(), text);

    // duplicate module line is deduped
    try std.testing.expectEqual(@as(usize, 2), pipeline.module_name_map.count());
    try std.testing.expect(pipeline.module_name_map.contains("format:01"));
    try std.testing.expect(pipeline.module_name_map.contains("i-raw:main"));

    const format_handle = pipeline.module_name_map.get("format:01").?;
    const format_mod = try pipeline.module_pool.getPtr(format_handle);
    const format_conn = format_mod.desc.sockets[0].?.private.connected_to_module.?;
    try std.testing.expectEqual(pipeline.module_name_map.get("i-raw:main").?, format_conn.item);

    const iraw_handle = pipeline.module_name_map.get("i-raw:main").?;
    const iraw_mod = try pipeline.module_pool.getPtr(iraw_handle);
    const filename = (try iraw_mod.getParamPtr("filename")).get([]const u8);
    try std.testing.expectEqualStrings("path/with space.NEF", filename);
}

test "preset deserialize skips bad lines leniently" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var repository = try Modules.Repository.init(allocator);
    defer repository.deinit();

    var pipeline = try Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();
    try pipeline.addRepo(&repository);

    const text =
        \\module:format:01
        \\module:draw:01
        \\param:format:01:bogus:1
        \\
        \\keyframe:0:1:2
        \\module:filmcurv:01
        \\param:filmcurv:01:brightness:abc
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // no error return: bad lines are warned and skipped
    try pie.serdes.deserialize(&pipeline, arena.allocator(), text);

    try std.testing.expect(pipeline.module_name_map.contains("format:01"));
    try std.testing.expect(!pipeline.module_name_map.contains("draw:01"));

    const filmcurv_handle = pipeline.module_name_map.get("filmcurv:01").?;
    const filmcurv_mod = try pipeline.module_pool.getPtr(filmcurv_handle);
    // garbage number did not clobber the default
    const brightness = (try filmcurv_mod.getParamPtr("brightness")).get(f32);
    try std.testing.expectEqual(@as(f32, 2.22), brightness);
}
