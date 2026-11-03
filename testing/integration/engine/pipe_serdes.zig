const std = @import("std");
const pie = @import("pie");

const Pipeline = pie.Pipeline;

/// Darkroom-style chain: i-raw -> format -> denoise -> demosaic -> crop ->
/// color -> filmcurv -> o-display, all instances "01", with darkroom's exact
/// params set (several non-default). Built through the recording edit ops so
/// `save`/`load` (the pipeline-level API under test) capture every step.
fn buildChain(p: *Pipeline) !void {
    const iraw = try p.addModule("i-raw", "01");
    const format = try p.addModule("format", "01");
    const denoise = try p.addModule("denoise", "01");
    const demosaic = try p.addModule("demosaic", "01");
    const crop = try p.addModule("crop", "01");
    const color = try p.addModule("color", "01");
    const filmcurv = try p.addModule("filmcurv", "01");
    const odisplay = try p.addModule("o-display", "01");

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

test "save emits vkdt-style lines for the recorded graph" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pipeline = try Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();

    try buildChain(&pipeline);

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try pipeline.save(&w.writer);
    const text = w.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "module:i-raw:01\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connect:i-raw:01:output:format:01:input\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "param:i-raw:01:filename:testing/images/DSC_6765.NEF\n") != null);
    // only edits that happened are recorded; untouched params are not present
    try std.testing.expect(std.mem.indexOf(u8, text, "param:format:01:") == null);
}

test "save/load round trip preserves pipeline state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pipe_a = try Pipeline.init(allocator, io, null, null);
    defer pipe_a.deinit();
    try buildChain(&pipe_a);

    var w_a = std.Io.Writer.Allocating.init(allocator);
    defer w_a.deinit();
    try pipe_a.save(&w_a.writer);
    const text_a = w_a.written();

    var pipe_b = try Pipeline.init(allocator, io, null, null);
    defer pipe_b.deinit();
    try pipe_b.load(text_a);

    var w_b = std.Io.Writer.Allocating.init(allocator);
    defer w_b.deinit();
    try pipe_b.save(&w_b.writer);
    try std.testing.expectEqualStrings(text_a, w_b.written());

    // structural checks on the loaded pipeline
    try std.testing.expectEqual(pipe_a.module_name_map.count(), pipe_b.module_name_map.count());

    const color_handle = pipe_b.module_name_map.get("color:01").?;
    const color_mod = try pipe_b.module_pool.getPtr(color_handle);
    const wb_coeff = (try color_mod.getParamPtr("wb_coeff")).get([3]f32);
    try std.testing.expectEqual(@as([3]f32, .{ 0.70393723, 1, 1.3611937 }), wb_coeff);

    const crop_handle = pipe_b.module_name_map.get("crop:01").?;
    const crop_mod = try pipe_b.module_pool.getPtr(crop_handle);
    const crop_conn = crop_mod.sockets[0].?.connected_to_module.?;
    try std.testing.expectEqual(pipe_b.module_name_map.get("demosaic:01").?, crop_conn.item);
}

test "load accepts vkdt syntax" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pipeline = try Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();

    const text =
        \\# a vkdt-style comment line
        \\module:format:01
        \\module:i-raw:main:100:200
        \\connect:i-raw:main:output:format:01:input
        \\param:i-raw:main:filename:path/with space.NEF
        \\module:format:01
    ;

    try pipeline.load(text);

    // duplicate module line is deduped
    try std.testing.expectEqual(@as(usize, 2), pipeline.module_name_map.count());
    try std.testing.expect(pipeline.module_name_map.contains("format:01"));
    try std.testing.expect(pipeline.module_name_map.contains("i-raw:main"));

    const format_handle = pipeline.module_name_map.get("format:01").?;
    const format_mod = try pipeline.module_pool.getPtr(format_handle);
    const format_conn = format_mod.sockets[0].?.connected_to_module.?;
    try std.testing.expectEqual(pipeline.module_name_map.get("i-raw:main").?, format_conn.item);

    const iraw_handle = pipeline.module_name_map.get("i-raw:main").?;
    const iraw_mod = try pipeline.module_pool.getPtr(iraw_handle);
    const filename = (try iraw_mod.getParamPtr("filename")).get([]const u8);
    try std.testing.expectEqualStrings("path/with space.NEF", filename);
}

test "load skips bad lines leniently" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pipeline = try Pipeline.init(allocator, io, null, null);
    defer pipeline.deinit();

    const text =
        \\module:format:01
        \\module:draw:01
        \\param:format:01:bogus:1
        \\
        \\bogus:0:1:2
        \\module:filmcurv:01
        \\param:filmcurv:01:brightness:abc
    ;

    // no error return: bad lines are warned and skipped
    try pipeline.load(text);

    try std.testing.expect(pipeline.module_name_map.contains("format:01"));
    try std.testing.expect(!pipeline.module_name_map.contains("draw:01"));

    const filmcurv_handle = pipeline.module_name_map.get("filmcurv:01").?;
    const filmcurv_mod = try pipeline.module_pool.getPtr(filmcurv_handle);
    // garbage number did not clobber the default
    const brightness = (try filmcurv_mod.getParamPtr("brightness")).get(f32);
    try std.testing.expectEqual(@as(f32, 2.22), brightness);
}
