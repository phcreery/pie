const std = @import("std");
const pie = @import("pie");

test "simple compute test" {
    var engine = try pie.gpu.GPU.init();
    defer engine.deinit();

    // https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/shader.wgsl
    const shader_code: []const u8 =
        \\enable f16;
        \\//requires readonly_and_readwrite_storage_textures;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn doubleMe(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let coords = vec2<i32>(global_id.xy);
        \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
        \\    pixel *= f32(2.0);
        \\    textureStore(output, coords, pixel);
        \\}
    ;
    var shader_pipe = try pie.gpu.ShaderPipe.init(&engine, shader_code, "doubleMe");
    defer shader_pipe.deinit();

    const region = pie.gpu.CopyRegionParams{
        .w = 256 / pie.gpu.BYTES_PER_PIXEL_RGBAf16,
        .h = 1,
    };

    var init_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    engine.mapUpload(&init_contents, region);

    engine.enqueueStage(&shader_pipe, region) catch unreachable;
    engine.enqueueShader(&shader_pipe, region);
    engine.enqueueDestage(&shader_pipe, region) catch unreachable;
    engine.run();

    const result = try engine.mapDownload(region);
    std.log.info("Download buffer contents: {any}", .{result[0..4]});

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}

test "simple compute double buffer test" {
    // if (true) {
    //     return error.SkipZigTest;
    // }
    var engine = try pie.gpu.GPU.init();
    defer engine.deinit();

    // https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/shader.wgsl
    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn doubleMe(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let coords = vec2<i32>(global_id.xy);
        \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
        \\    pixel *= f32(2.0);
        \\    textureStore(output, coords, pixel);
        \\}
    ;
    var shader_pipe = try pie.gpu.ShaderPipe.init(&engine, shader_code, "doubleMe");
    defer shader_pipe.deinit();

    const region = pie.gpu.CopyRegionParams{
        .w = 256 / pie.gpu.BYTES_PER_PIXEL_RGBAf16,
        .h = 1,
    };

    var init_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    engine.mapUpload(&init_contents, region);

    engine.enqueueStage(&shader_pipe, region) catch unreachable;
    engine.enqueueShader(&shader_pipe, region);
    shader_pipe.swapBuffers();
    engine.enqueueShader(&shader_pipe, region);
    engine.enqueueDestage(&shader_pipe, region) catch unreachable;
    engine.run();

    const result = try engine.mapDownload(region);
    std.log.info("Download buffer contents: {any}", .{result[0..4]});

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 4.0, 8.0, 12.0, 16.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
