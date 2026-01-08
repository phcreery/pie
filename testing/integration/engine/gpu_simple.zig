const std = @import("std");
const pie = @import("pie");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const Buffer = pie.engine.gpu.Buffer;
const Encoder = pie.engine.gpu.Encoder;
const Shader = pie.engine.gpu.Shader;
const ComputePipeline = pie.engine.gpu.ComputePipeline;
const Texture = pie.engine.gpu.Texture;
const Bindings = pie.engine.gpu.Bindings;
const TextureFormat = pie.engine.gpu.TextureFormat;
const BindGroupLayoutEntry = pie.engine.gpu.BindGroupLayoutEntry;
const BindGroupEntry = pie.engine.gpu.BindGroupEntry;

test "simple compute test" {
    // INIT
    var gpu = try GPU.init();
    defer gpu.deinit();

    // these are intentionally over-provisioned to avoid OOM issues
    var upload = try Buffer.init(&gpu, 256 * TextureFormat.rgba16float.bpp(), .upload);
    defer upload.deinit();
    var download = try Buffer.init(&gpu, 256 * TextureFormat.rgba16float.bpp(), .download);
    defer download.deinit();

    // DEFINE
    const source = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
    const source_format = TextureFormat.rgba16float;
    var destination = std.mem.zeroes([4]f16);
    const destination_format = TextureFormat.rgba16float;
    const roi = ROI{
        .w = 1,
        .h = 1,
    };
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

    var layout_group_0_binding: [pie.engine.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group_0_binding[0] = .{ .texture = .{ .access = .read, .format = .rgba16float } };
    layout_group_0_binding[1] = .{ .texture = .{ .access = .write, .format = .rgba16float } };

    var layout_group: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group[0] = layout_group_0_binding;

    var compute_pipeline = try ComputePipeline.init(&gpu, shader, "doubleMe", layout_group);
    defer compute_pipeline.deinit();

    // MEMORY
    var texture_in = try Texture.init(&gpu, "in", source_format, roi);
    defer texture_in.deinit();

    var texture_out = try Texture.init(&gpu, "out", destination_format, roi);
    defer texture_out.deinit();

    var bind_group_0_binds: [pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_0_binds[0] = .{ .texture = texture_in };
    bind_group_0_binds[1] = .{ .texture = texture_out };

    var bind_group: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group[0] = bind_group_0_binds;

    var bindings = try Bindings.init(&gpu, &compute_pipeline, bind_group);
    defer bindings.deinit();

    // ALLOCATORS
    var upload_fba = upload.fixedBufferAllocator();
    var upload_allocator = upload_fba.allocator();
    // pre-allocate to induce a change in offset
    _ = try upload_allocator.alloc(f16, roi.w * roi.h * source_format.nchannels());

    var download_fba = download.fixedBufferAllocator();
    var download_allocator = download_fba.allocator();

    // PREP UPLOAD
    const upload_offset = upload_fba.end_index;
    const upload_buf = try upload_allocator.alloc(f16, roi.w * roi.h * source_format.nchannels());
    // const offset = upload_buf.ptr - upload_fba.buffer.ptr
    std.log.info("Upload offset: {d}", .{upload_offset});

    // PREP DOWNLOAD
    const download_offset = download_fba.end_index;
    const download_buf = try download_allocator.alloc(f16, roi.w * roi.h * destination_format.nchannels());

    // UPLOAD
    upload.map();
    @memcpy(upload_buf, &source);
    upload.unmap();

    // RUN
    var encoder = try Encoder.start(&gpu);
    defer encoder.deinit();
    encoder.enqueueBufToTex(&upload, upload_offset, &texture_in, roi) catch unreachable;
    encoder.enqueueShader(&compute_pipeline, &bindings, roi);
    encoder.enqueueTexToBuf(&download, download_offset, &texture_out, roi) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    download.map();
    @memcpy(&destination, download_buf);
    download.unmap();

    std.log.info("Download buffer contents: {any}", .{destination[0..4]});

    const expected_contents = [_]f16{ 2.0, 4.0, 6.0, 8.0 };
    try std.testing.expectEqualSlices(f16, &expected_contents, &destination);
}
