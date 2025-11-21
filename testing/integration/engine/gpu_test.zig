const std = @import("std");
const pie = @import("pie");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const GPUAllocator = pie.engine.gpu.GPUAllocator;
const Encoder = pie.engine.gpu.Encoder;
const ShaderPipe = pie.engine.gpu.ShaderPipe;
const Texture = pie.engine.gpu.Texture;
const Bindings = pie.engine.gpu.Bindings;
const TextureFormat = pie.engine.gpu.TextureFormat;

test "simple compute test" {
    var gpu = try GPU.init();
    defer gpu.deinit();

    var gpu_allocator = try GPUAllocator.init(&gpu, 256 * TextureFormat.rgba16float.bpp());
    defer gpu_allocator.deinit();

    var init_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    const roi = ROI{
        .size = .{
            .w = 256 / TextureFormat.rgba16float.nchannels(),
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
    const input_layout = pie.engine.gpu.BindGroupLayoutEntry{
        .binding = 0,
        .type = .read,
        .format = .rgba16float,
    };
    const output_layout = pie.engine.gpu.BindGroupLayoutEntry{
        .binding = 1,
        .type = .write,
        .format = .rgba16float,
    };
    var layout: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupLayoutEntry = @splat(null);
    layout[0] = input_layout;
    layout[1] = output_layout;
    var shader_pipe = try ShaderPipe.init(&gpu, shader_code, "doubleMe", layout);
    defer shader_pipe.deinit();

    // MEMORY
    var texture_in = try Texture.init(&gpu, "in", input_layout.format, roi);
    defer texture_in.deinit();

    var texture_out = try Texture.init(&gpu, "out", output_layout.format, roi);
    defer texture_out.deinit();

    var binds: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupEntry = @splat(null);
    binds[0] = .{ .binding = 0, .type = .texture, .texture = texture_in };
    binds[1] = .{ .binding = 1, .type = .texture, .texture = texture_out };
    var bindings = try Bindings.init(&gpu, &shader_pipe, binds);
    defer bindings.deinit();

    // UPLOAD
    var uploader = gpu_allocator.uploader() catch unreachable;
    const upload_buf = try uploader.allocator.alloc(f16, roi.size.w * roi.size.h * input_layout.format.nchannels());
    @memcpy(upload_buf, &init_contents);
    uploader.deinit(&gpu_allocator);

    // RUN
    var encoder = try Encoder.start(&gpu);
    defer encoder.deinit();
    encoder.enqueueBufToTex(&gpu_allocator, &texture_in, roi) catch unreachable;
    encoder.enqueueShader(&shader_pipe, &bindings, roi);
    encoder.enqueueTexToBuf(&gpu_allocator, &texture_out, roi) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    // const result = try gpu_allocator.download(f16, .rgba16float, roi);

    const downloader = gpu_allocator.downloader() catch unreachable;
    const download_buffer_ptr: []f16 = @ptrCast(@alignCast(downloader.buf));
    const size_nvals = roi.size.w * roi.size.h * output_layout.format.nchannels();
    const result = download_buffer_ptr[0..size_nvals];
    defer downloader.deinit(&gpu_allocator);
    std.log.info("Download buffer contents: {any}", .{result[0..4]});

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
