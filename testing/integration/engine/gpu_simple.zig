const std = @import("std");
const pie = @import("pie");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const GPUAllocator = pie.engine.gpu.GPUAllocator;
const Encoder = pie.engine.gpu.Encoder;
const ShaderPipe = pie.engine.gpu.ShaderPipe;
const Texture = pie.engine.gpu.Texture;
const Bindings = pie.engine.gpu.Bindings;
const BPP_RGBAf16 = pie.engine.gpu.BPP_RGBAf16;

test "simple compute test" {
    // const allocator = std.testing.allocator;

    var gpu = try GPU.init();
    defer gpu.deinit();

    var gpu_allocator = try GPUAllocator.init(&gpu);
    defer gpu_allocator.deinit();

    var init_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
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
    const conns = [_]pie.engine.gpu.ShaderPipeConn{ .{
        .binding = 0,
        .type = .input,
        .format = .rgba16float,
    }, .{
        .binding = 1,
        .type = .output,
        .format = .rgba16float,
    } };
    var shader_pipe = try ShaderPipe.init(&gpu, shader_code, "doubleMe", &conns);
    defer shader_pipe.deinit();

    // MEMORY
    var texture_in = try Texture.init(&gpu, conns[0].format, roi);
    defer texture_in.deinit();

    var texture_out = try Texture.init(&gpu, conns[1].format, roi);
    defer texture_out.deinit();

    var bindings = try Bindings.init(&gpu, &shader_pipe, &texture_in, &texture_out);
    defer bindings.deinit();

    // UPLOAD
    gpu.mapUpload(&gpu_allocator, f16, &init_contents, .rgba16float, roi);

    // RUN
    var encoder = try Encoder.start(&gpu);
    defer encoder.deinit();
    encoder.enqueueMount(&gpu_allocator, &texture_in, roi) catch unreachable;
    encoder.enqueueShader(&shader_pipe, &bindings, roi);
    encoder.enqueueUnmount(&gpu_allocator, &texture_out, roi) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    const result = try gpu.mapDownload(&gpu_allocator, f16, .rgba16float, roi);
    std.log.info("Download buffer contents: {any}", .{result[0..4]});

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
