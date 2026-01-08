const std = @import("std");
const pie = @import("pie");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const Buffer = pie.engine.gpu.Buffer;
const Encoder = pie.engine.gpu.Encoder;
const Shader = pie.engine.gpu.Shader;
const ComputePipeline = pie.engine.gpu.ComputePipeline;
const Texture = pie.engine.gpu.Texture;
const TextureFormat = pie.engine.gpu.TextureFormat;
const Bindings = pie.engine.gpu.Bindings;

test "simple compute double buffer test" {
    var gpu = try GPU.init();
    defer gpu.deinit();

    var upload = try Buffer.init(&gpu, 4 * TextureFormat.rgba16float.bpp(), .upload);
    defer upload.deinit();
    var download = try Buffer.init(&gpu, 4 * TextureFormat.rgba16float.bpp(), .download);
    defer download.deinit();

    const format = TextureFormat.rgba16float;
    const source = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
    var destination = std.mem.zeroes([4]f16);
    const roi = ROI{
        .w = 1,
        .h = 1,
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
    const shader = Shader.compile(&gpu, shader_code, .{}) catch unreachable;

    var layout_group_0_binding: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupLayoutEntry = @splat(null);
    layout_group_0_binding[0] = .{ .texture = .{ .access = .read, .format = .rgba16float } };
    layout_group_0_binding[1] = .{ .texture = .{ .access = .write, .format = .rgba16float } };
    // see https://github.com/ziglang/zig/issues/6068
    // const binding_layout = init: {
    //     var s: [pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupLayoutEntry = @splat(null);
    //     s[0] = input_binding_layout;
    //     s[1] = output_binding_layout;
    //     break :init s;
    // };
    var layout_group: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupLayoutEntry = @splat(null);
    layout_group[0] = layout_group_0_binding;
    var compute_pipeline = try ComputePipeline.init(&gpu, shader, "doubleMe", layout_group);
    defer compute_pipeline.deinit();

    // MEMORY
    var texture_a = try Texture.init(&gpu, "a", format, roi);
    defer texture_a.deinit();

    var texture_b = try Texture.init(&gpu, "b", format, roi);
    defer texture_b.deinit();

    var bind_group_a_to_b: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupEntry = @splat(null);
    bind_group_a_to_b[0] = @splat(null);
    bind_group_a_to_b[0].?[0] = .{ .texture = texture_a };
    bind_group_a_to_b[0].?[1] = .{ .texture = texture_b };
    var bindings_a_to_b = try Bindings.init(&gpu, &compute_pipeline, bind_group_a_to_b);
    defer bindings_a_to_b.deinit();

    var bind_group_b_to_a: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?pie.engine.gpu.BindGroupEntry = @splat(null);
    bind_group_b_to_a[0] = @splat(null);
    bind_group_b_to_a[0].?[0] = .{ .texture = texture_b };
    bind_group_b_to_a[0].?[1] = .{ .texture = texture_a };
    var bindings_b_to_a = try Bindings.init(&gpu, &compute_pipeline, bind_group_b_to_a);
    defer bindings_b_to_a.deinit();

    // ALLOCATORS
    var upload_fba = upload.fixedBufferAllocator();
    var upload_allocator = upload_fba.allocator();
    // pre-allocate to induce a change in offset
    _ = try upload_allocator.alloc(f16, roi.w * roi.h * format.nchannels());

    var download_fba = download.fixedBufferAllocator();
    var download_allocator = download_fba.allocator();

    // PREP UPLOAD
    const upload_offset = upload_fba.end_index;
    const upload_buf = try upload_allocator.alloc(f16, roi.w * roi.h * format.nchannels());
    // const offset = upload_buf.ptr - upload_fba.buffer.ptr
    std.log.info("Upload offset: {d}", .{upload_offset});

    // PREP DOWNLOAD
    const download_offset = download_fba.end_index;
    const download_buf = try download_allocator.alloc(f16, roi.w * roi.h * format.nchannels());

    // UPLOAD
    upload.map();
    @memcpy(upload_buf, &source);
    upload.unmap();

    // a -> b -> a
    var encoder = try Encoder.start(&gpu);
    defer encoder.deinit();
    encoder.enqueueBufToTex(&upload, upload_offset, &texture_a, roi) catch unreachable;
    encoder.enqueueShader(&compute_pipeline, &bindings_a_to_b, roi);
    encoder.enqueueShader(&compute_pipeline, &bindings_b_to_a, roi);
    encoder.enqueueTexToBuf(&download, download_offset, &texture_a, roi) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    download.map();
    @memcpy(&destination, download_buf);
    download.unmap();

    std.log.info("Download buffer contents: {any}", .{destination});

    const expected_contents = [_]f16{ 4.0, 8.0, 12.0, 16.0 };
    try std.testing.expectEqualSlices(f16, &expected_contents, &destination);
}
