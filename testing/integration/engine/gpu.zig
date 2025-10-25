const std = @import("std");
const pie = @import("pie");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const ShaderPipe = pie.engine.gpu.ShaderPipe;
const Texture = pie.engine.gpu.Texture;
const Bindings = pie.engine.gpu.Bindings;
const BPP_RGBAf16 = pie.engine.gpu.BPP_RGBAf16;

test "simple compute test" {
    var engine = try GPU.init();
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
    var shader_pipe = try ShaderPipe.init(&engine, shader_code, "doubleMe");
    defer shader_pipe.deinit();

    // MEMORY
    var texture_in = try Texture.init(&engine);
    defer texture_in.deinit();

    var texture_out = try Texture.init(&engine);
    defer texture_out.deinit();

    var bindings = try Bindings.init(&engine, &shader_pipe, &texture_in, &texture_out);
    defer bindings.deinit();

    const roi = ROI{
        .size = .{
            .w = 256 / BPP_RGBAf16,
            .h = 1,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };

    var init_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    engine.mapUpload(&init_contents, roi);

    engine.enqueueMount(&texture_in, roi) catch unreachable;
    engine.enqueueShader(&shader_pipe, &bindings, roi);
    engine.enqueueUnmount(&texture_out, roi) catch unreachable;
    engine.run();

    const result = try engine.mapDownload(roi);
    std.log.info("Download buffer contents: {any}", .{result[0..4]});

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}

test "simple compute double buffer test" {
    // if (true) {
    //     return error.SkipZigTest;
    // }
    var engine = try GPU.init();
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
    var shader_pipe = try ShaderPipe.init(&engine, shader_code, "doubleMe");
    defer shader_pipe.deinit();

    // MEMORY
    var texture_a = try Texture.init(&engine);
    defer texture_a.deinit();

    var texture_b = try Texture.init(&engine);
    defer texture_b.deinit();

    var bindings_a_to_b = try Bindings.init(&engine, &shader_pipe, &texture_a, &texture_b);
    defer bindings_a_to_b.deinit();
    var bindings_b_to_a = try Bindings.init(&engine, &shader_pipe, &texture_b, &texture_a);
    defer bindings_b_to_a.deinit();

    const roi = ROI{
        .size = .{
            .w = 256 / BPP_RGBAf16,
            .h = 1,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };

    var init_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    engine.mapUpload(&init_contents, roi);

    // a -> b -> a
    engine.enqueueMount(&texture_a, roi) catch unreachable;
    engine.enqueueShader(&shader_pipe, &bindings_a_to_b, roi);
    engine.enqueueShader(&shader_pipe, &bindings_b_to_a, roi);
    engine.enqueueUnmount(&texture_a, roi) catch unreachable;
    engine.run();

    const result = try engine.mapDownload(roi);
    std.log.info("Download buffer contents: {any}", .{result[0..4]});

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 4.0, 8.0, 12.0, 16.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
