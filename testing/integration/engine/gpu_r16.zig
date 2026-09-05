const std = @import("std");
const pie = @import("pie");

const ROI = pie.ROI;
const GPU = pie.gpu.GPU;
const Buffer = pie.gpu.Buffer;
const Encoder = pie.gpu.Encoder;
const Shader = pie.gpu.Shader;
const ComputePipeline = pie.gpu.ComputePipeline;
const Texture = pie.gpu.Texture;
const Bindings = pie.gpu.Bindings;
const TextureFormat = pie.gpu.TextureFormat;
const BindGroupLayoutEntry = pie.gpu.BindGroupLayoutEntry;
const BindGroupEntry = pie.gpu.BindGroupEntry;

test "r16uint -> r16float -> double -> download" {
    // INIT
    const allocator = std.testing.allocator;
    var gpu = try GPU.init(allocator, std.testing.io);
    defer gpu.deinit();

    const w = 4;
    const h = 4;
    const roi = ROI{ .w = w, .h = h };

    // upload needs bytesPerRow padded to COPY_BYTES_PER_ROW_ALIGNMENT (256);
    // a 4-wide r16 row is 8 bytes -> 256 padded, x4 rows = 1 KiB; give headroom
    var upload = try Buffer.init(&gpu, 2048, .upload);
    defer upload.deinit();
    var download = try Buffer.init(&gpu, 2048, .download);
    defer download.deinit();

    // DEFINE
    const source = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var destination = std.mem.zeroes([16]f16);

    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<u32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<r16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn convertAndDouble(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let coords = vec2<i32>(global_id.xy);
        \\    let raw = textureLoad(input, coords, 0);
        \\    let v = f32(raw.x) * 2.0;
        \\    textureStore(output, coords, vec4<f32>(v, 0.0, 0.0, 1.0));
        \\}
    ;

    // NOTE: storage texel format `r16float` is not in the WGSL spec's
    // normative list, but naga (bundled in wgpu-native v29) parses and
    // validates it. If this test fails at pipeline creation that's why.

    var shader = Shader.compile(&gpu, .{ .wgsl = shader_code }) catch |e| {
        std.log.err("r16float storage shader compile failed: {any}", .{e});
        return e;
    };
    defer shader.deinit();

    var layout_group_0_binding: [pie.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group_0_binding[0] = .{ .texture = .{ .access = .read, .format = .r16uint } };
    layout_group_0_binding[1] = .{ .texture = .{ .access = .write, .format = .r16float } };

    var layout_group: [pie.gpu.MAX_BIND_GROUPS]?[pie.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group[0] = layout_group_0_binding;

    var compute_pipeline = try ComputePipeline.init(&gpu, shader, "convertAndDouble", layout_group);
    defer compute_pipeline.deinit();

    // MEMORY
    var texture_in = try Texture.init(&gpu, "in", .r16uint, roi);
    defer texture_in.deinit();

    var texture_out = try Texture.init(&gpu, "out", .r16float, roi);
    defer texture_out.deinit();

    var bind_group_0_binds: [pie.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_0_binds[0] = .{ .texture = texture_in };
    bind_group_0_binds[1] = .{ .texture = texture_out };

    var bind_group: [pie.gpu.MAX_BIND_GROUPS]?[pie.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group[0] = bind_group_0_binds;

    var bindings = try Bindings.init(&gpu, &compute_pipeline, bind_group);
    defer bindings.deinit();

    // wgpu requires bytesPerRow >= 256 for texel copies; width-4 r16 = 8 bytes
    // -> 256 padded per row
    const bytes_per_row = roi.w * TextureFormat.r16uint.bpp();
    const padded_bytes_per_row = ((bytes_per_row + pie.gpu.COPY_BYTES_PER_ROW_ALIGNMENT - 1) / pie.gpu.COPY_BYTES_PER_ROW_ALIGNMENT) * pie.gpu.COPY_BYTES_PER_ROW_ALIGNMENT;
    const texel_count_per_row = padded_bytes_per_row / TextureFormat.r16uint.bpp();

    // ALLOCATORS
    var upload_fba = try upload.fixedBufferAllocator();
    var upload_allocator = upload_fba.allocator();
    var download_fba = try download.fixedBufferAllocator();
    var download_allocator = download_fba.allocator();

    // PREP UPLOAD (padded rows of u16)
    const upload_buf = try upload_allocator.alignedAlloc(u16, pie.gpu.COPY_BUFFER_ALIGNMENT, texel_count_per_row * roi.h);
    const upload_offset = @intFromPtr(upload_buf.ptr) - @intFromPtr(upload_fba.ptr);
    std.log.info("Upload offset: {d}", .{upload_offset});

    // PREP DOWNLOAD (padded rows of f16)
    const download_buf = try download_allocator.alignedAlloc(f16, pie.gpu.COPY_BUFFER_ALIGNMENT, texel_count_per_row * roi.h);
    const download_offset = @intFromPtr(download_buf.ptr) - @intFromPtr(download_fba.ptr);

    // UPLOAD: place source into the padded rows (4 per row, rest zero-padded)
    upload.map();
    @memset(upload_buf, 0);
    for (0..h) |row| {
        const row_start = row * texel_count_per_row;
        for (0..w) |col| {
            upload_buf[row_start + col] = source[row * w + col];
        }
    }
    upload.unmap();

    // RUN
    var encoder = try Encoder.start(&gpu);
    defer encoder.deinit();
    encoder.enqueueBufToTex(&upload, upload_offset, &texture_in, roi) catch unreachable;
    encoder.enqueueShader(&compute_pipeline, &bindings, roi);
    encoder.enqueueTexToBuf(&download, download_offset, &texture_out, roi) catch unreachable;
    try gpu.run(encoder.finish());

    // DOWNLOAD: read back the padded rows, first w per row
    download.map();
    for (0..h) |row| {
        const row_start = row * texel_count_per_row;
        for (0..w) |col| {
            destination[row * w + col] = download_buf[row_start + col];
        }
    }
    download.unmap();

    std.log.info("Download buffer contents: {any}", .{destination[0..16]});

    const expected_contents = [_]f16{ 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32 };
    try std.testing.expectEqualSlices(f16, &expected_contents, &destination);
}