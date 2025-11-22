const std = @import("std");
const pie = @import("pie");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const GPUMemory = pie.engine.gpu.GPUMemory;
const Encoder = pie.engine.gpu.Encoder;
const ShaderPipe = pie.engine.gpu.ShaderPipe;
const Texture = pie.engine.gpu.Texture;
const TextureFormat = pie.engine.gpu.TextureFormat;
const Bindings = pie.engine.gpu.Bindings;

test "simple compute double buffer test" {
    // if (true) {
    //     return error.SkipZigTest;
    // }
    var gpu = try GPU.init();
    defer gpu.deinit();

    var gpu_allocator = try GPUMemory.init(&gpu, 4 * TextureFormat.rgba16float.bpp());
    defer gpu_allocator.deinit();

    var init_contents = std.mem.zeroes([4]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    const roi = ROI{
        .size = .{
            .w = 1,
            .h = 1,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };

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
    const input_binding_layout = pie.engine.gpu.BindGroupLayoutEntry{
        .binding = 0,
        .type = .read,
        .format = .rgba16float,
    };
    const output_binding_layout = pie.engine.gpu.BindGroupLayoutEntry{
        .binding = 1,
        .type = .write,
        .format = .rgba16float,
    };
    // see https://github.com/ziglang/zig/issues/6068
    // const binding_layout = init: {
    //     var s: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupLayoutEntry = @splat(null);
    //     s[0] = input_binding_layout;
    //     s[1] = output_binding_layout;
    //     break :init s;
    // };
    var binding_layout: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupLayoutEntry = @splat(null);
    binding_layout[0] = input_binding_layout;
    binding_layout[1] = output_binding_layout;
    var shader_pipe = try ShaderPipe.init(&gpu, shader_code, "doubleMe", binding_layout);
    defer shader_pipe.deinit();

    // MEMORY
    var texture_a = try Texture.init(&gpu, "a", input_binding_layout.format, roi);
    defer texture_a.deinit();

    var texture_b = try Texture.init(&gpu, "b", output_binding_layout.format, roi);
    defer texture_b.deinit();

    var binds_a_to_b: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupEntry = @splat(null);
    binds_a_to_b[0] = .{ .binding = 0, .type = .texture, .texture = texture_a };
    binds_a_to_b[1] = .{ .binding = 1, .type = .texture, .texture = texture_b };
    var bindings_a_to_b = try Bindings.init(&gpu, &shader_pipe, binds_a_to_b);
    defer bindings_a_to_b.deinit();

    var binds_b_to_a: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupEntry = @splat(null);
    binds_b_to_a[0] = .{ .binding = 0, .type = .texture, .texture = texture_b };
    binds_b_to_a[1] = .{ .binding = 1, .type = .texture, .texture = texture_a };
    var bindings_b_to_a = try Bindings.init(&gpu, &shader_pipe, binds_b_to_a);
    defer bindings_b_to_a.deinit();

    // UPLOAD
    gpu_allocator.upload(f16, &init_contents, .rgba16float, roi);

    // a -> b -> a
    var encoder = try Encoder.start(&gpu);
    defer encoder.deinit();
    encoder.enqueueBufToTex(&gpu_allocator, &texture_a, roi) catch unreachable;
    encoder.enqueueShader(&shader_pipe, &bindings_a_to_b, roi);
    encoder.enqueueShader(&shader_pipe, &bindings_b_to_a, roi);
    encoder.enqueueTexToBuf(&gpu_allocator, &texture_a, roi) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    const result = try gpu_allocator.download(f16, .rgba16float, roi);
    std.log.info("Download buffer contents: {any}", .{result});

    const expected_contents = [_]f16{ 4.0, 8.0, 12.0, 16.0 };
    try std.testing.expectEqualSlices(f16, &expected_contents, result);
}
