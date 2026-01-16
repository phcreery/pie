const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

const ROI = pie.engine.ROI;
const GPU = pie.engine.gpu.GPU;
const Buffer = pie.engine.gpu.Buffer;
const Encoder = pie.engine.gpu.Encoder;
const Shader = pie.engine.gpu.Shader;
const ComputePipeline = pie.engine.gpu.ComputePipeline;
const Texture = pie.engine.gpu.Texture;
const TextureFormat = pie.engine.gpu.TextureFormat;
const Bindings = pie.engine.gpu.Bindings;
const BindGroupEntry = pie.engine.gpu.BindGroupEntry;
const BindGroupLayoutEntry = pie.engine.gpu.BindGroupLayoutEntry;

fn printImgBufContents(comptime T: type, ibuf: []T, stride: u32) void {
    const n = 8;
    std.debug.print("[{d}..{d}] {any} ...\n", .{ 0, n, ibuf[0..n] });
    std.debug.print("[{d}..{d}] {any} ...\n", .{ stride, stride + n, ibuf[stride .. stride + n] });
    std.debug.print("[{d}..{d}] {any} ...\n", .{ stride * 2, stride * 2 + n, ibuf[stride * 2 .. stride * 2 + n] });
    std.debug.print("[{d}..{d}] {any} ...\n", .{ stride * 3, stride * 3 + n, ibuf[stride * 3 .. stride * 3 + n] });
    std.debug.print("... ... ... ...\n", .{});
    std.debug.print("[{d}..{d}] ... {any}\n", .{ ibuf.len - n, ibuf.len, ibuf[ibuf.len - n .. ibuf.len] });
}

test "load raw, demosaic, save" {
    // if (true) {
    //     return error.SkipZigTest;
    // }
    const allocator = std.testing.allocator;

    // Read contents from file
    const file_name = "testing/images/DSC_6765.NEF";
    const file = try std.fs.cwd().openFile(file_name, .{});
    var pie_raw_image = try pie.engine.modules.i_raw.RawImage.read(allocator, file);
    defer pie_raw_image.deinit();

    // flattened u16 array of the 2d rggb array
    const init_contents_u16: []u16 = pie_raw_image.raw_image;

    try std.testing.expectEqual(init_contents_u16.len, @as(u32, @intCast(pie_raw_image.width * pie_raw_image.height)));

    // if (true) {
    //     return error.SkipZigTest;
    // }

    // EXPORT
    // {
    //     const byte_array = std.mem.sliceAsBytes(init_contents_f16);
    //     std.log.info("Giving to zigimg", .{});
    //     var zigimage = try zigimg.Image.fromRawPixels(allocator, img_width, img_height, byte_array[0..], .float32);
    //     defer zigimage.deinit(allocator);
    //     // std.log.info("zigimg reads as: {any}", .{zigimage.pixels.float32[0..8]});
    //     try zigimage.convert(allocator, .rgba64);

    //     var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    //     try zigimage.writeToFilePath(allocator, "testing/images/DSC_6765.png", write_buffer[0..], .{ .png = .{} });
    // }

    // // EXPORT RAW
    // {
    //     // 1. Open or create the file
    //     var file_raw = try std.fs.cwd().createFile("testing/images/DSC_6765.raw", .{ .read = true });
    //     defer file_raw.close();

    //     // 2. Create a buffer for the writer
    //     var write_buffer: [1024]u8 = undefined;

    //     // 3. Obtain the std.Io.Writer
    //     var writer = file_raw.writer(&write_buffer);

    //     // 4. Write the data from your buffer
    //     const byte_array = std.mem.sliceAsBytes(init_contents_f32);
    //     try writer.interface.writeAll(byte_array);

    //     // 5. Flush the writer to ensure all data is written to disk
    //     try writer.interface.flush();
    // }

    // SIZES
    const image_size_in_w = @as(u32, @intCast(pie_raw_image.width));
    const image_size_in_h = @as(u32, @intCast(pie_raw_image.height));
    const source_format = TextureFormat.rgba16float;
    const destination_format = TextureFormat.rgba16float;

    var roi_in = pie.engine.ROI.full(image_size_in_w, image_size_in_h);

    // THIS IS A WORKAROUND: I don't seem that wgpu supports single channel f16 storage textures.
    // see "texture-formats-tier2" in webgpu spec
    // "The adapter does not support write access for storage textures of format R16Float"
    // so will will pack it into a RGBA16Float
    roi_in = roi_in.div(4, 1); // we have 1/4 width input (packed RG/GB)

    var roi_out = roi_in;
    var roi_in_upper, var roi_in_lower = roi_in.splitH();
    var roi_out_upper, var roi_out_lower = roi_out.splitH();

    // since we are splitting the texture and buffer by hand, set x and y to 0
    roi_in_upper.x = 0;
    roi_in_upper.y = 0;
    roi_out_upper.x = 0;
    roi_out_upper.y = 0;
    roi_in_lower.x = 0;
    roi_in_lower.y = 0;
    roi_out_lower.x = 0;
    roi_out_lower.y = 0;

    var gpu = try pie.engine.gpu.GPU.init();
    defer gpu.deinit();

    // these are intentionally over-provisioned to avoid OOM issues
    const some_size_larger_than_needed = 20 * pie_raw_image.width * pie_raw_image.height * TextureFormat.r16float.bpp();
    var upload = try Buffer.init(&gpu, some_size_larger_than_needed, .upload);
    defer upload.deinit();
    var download = try Buffer.init(&gpu, some_size_larger_than_needed, .download);
    defer download.deinit();

    // ALLOCATORS
    var upload_fba = try upload.fixedBufferAllocator();
    var upload_allocator = upload_fba.allocator();

    var download_fba = try download.fixedBufferAllocator();
    var download_allocator = download_fba.allocator();

    // PREP UPLOAD
    // const upload_offset_upper = upload_fba.end_index;
    const upload_buf_upper = try upload_allocator.alignedAlloc(u8, pie.engine.gpu.COPY_BUFFER_ALIGNMENT, roi_in_upper.w * roi_in_upper.h * source_format.bpp());
    const upload_offset_upper = @intFromPtr(upload_buf_upper.ptr) - @intFromPtr(upload_fba.ptr);
    // const upload_offset_lower = upload_fba.end_index;
    const upload_buf_lower = try upload_allocator.alignedAlloc(u8, pie.engine.gpu.COPY_BUFFER_ALIGNMENT, roi_in_lower.w * roi_in_lower.h * source_format.bpp());
    const upload_offset_lower = @intFromPtr(upload_buf_lower.ptr) - @intFromPtr(upload_fba.ptr);

    // PREP DOWNLOAD
    // const download_offset_upper = download_fba.end_index;
    const download_buf_upper = try download_allocator.alignedAlloc(u8, pie.engine.gpu.COPY_BUFFER_ALIGNMENT, roi_out_upper.w * roi_out_upper.h * destination_format.bpp());
    const download_offset_upper = @intFromPtr(download_buf_upper.ptr) - @intFromPtr(download_fba.ptr);
    // const download_offset_lower = download_fba.end_index;
    const download_buf_lower = try download_allocator.alignedAlloc(u8, pie.engine.gpu.COPY_BUFFER_ALIGNMENT, roi_out_lower.w * roi_out_lower.h * destination_format.bpp());
    const download_offset_lower = @intFromPtr(download_buf_lower.ptr) - @intFromPtr(download_fba.ptr);

    // print offsets
    // std.log.info("Upload offset upper: {d}", .{upload_offset_upper});
    // std.log.info("Upload offset lower: {d}", .{upload_offset_lower});
    // std.log.info("Download offset upper: {d}", .{download_offset_upper});
    // std.log.info("Download offset lower: {d}", .{download_offset_lower});

    // UPLOAD
    upload.map();
    @memcpy(upload_buf_upper, @as([*]u8, @ptrCast(@alignCast(init_contents_u16[0 .. roi_in_upper.w * roi_in_upper.h * source_format.nchannels()]))));
    @memcpy(upload_buf_lower, @as([*]u8, @ptrCast(@alignCast(init_contents_u16[roi_in_upper.w * roi_in_upper.h * source_format.nchannels() ..]))));
    upload.unmap();

    var encoder = try pie.engine.gpu.Encoder.start(&gpu);
    defer encoder.deinit();

    // FORMAT CONVERSION WITH COMPUTE SHADER
    // const convert: []const u8 =
    //     \\enable f16;
    //     \\@group(0) @binding(0) var input:  texture_2d<u32>;
    //     \\@group(0) @binding(1) var output: texture_storage_2d<r16float, write>;
    //     \\@compute @workgroup_size(8, 8, 1)
    //     \\fn convert(@builtin(global_invocation_id) global_id: vec3<u32>) {
    //     \\    var coords = vec2<i32>(global_id.xy);
    //     \\    // textureLoad always returns a vec4, even for single channel textures
    //     \\    let px = textureLoad(input, coords, 0);
    //     \\    // textureLoad always expects vec4, even for single channel textures
    //     \\    let pxf = vec4<f32>(f32(px.r), 0.0, 0.0, 1.0) / 4096.0; // max_value
    //     \\    //let pxf = f32(px.r) / 4096.0; // max_value
    //     \\    textureStore(output, coords, pxf);
    //     \\}
    // ;

    // THIS IS A WORKAROUND
    const convert: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<u32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn convert(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    let px = textureLoad(input, coords, 0);
        \\    let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a)) / 4096.0; // max_value
        \\    textureStore(output, coords, pxf);
        \\}
    ;
    var shader_convert = try Shader.compile(&gpu, convert, .{});
    defer shader_convert.deinit();

    var layout_group_0_binding_convert: [pie.engine.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group_0_binding_convert[0] = .{ .texture = .{ .access = .read, .format = .rgba16uint } };
    layout_group_0_binding_convert[1] = .{ .texture = .{ .access = .write, .format = .rgba16float } };

    var layout_group_convert: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group_convert[0] = layout_group_0_binding_convert;

    var convert_compute_pipeline = try ComputePipeline.init(&gpu, shader_convert, "convert", layout_group_convert);
    defer convert_compute_pipeline.deinit();

    // UPPER MEMORY
    var texture_upper_in = try Texture.init(&gpu, "upper_in", layout_group_0_binding_convert[0].?.texture.?.format, roi_in_upper);
    defer texture_upper_in.deinit();

    var texture_upper_out = try Texture.init(&gpu, "upper_out", layout_group_0_binding_convert[1].?.texture.?.format, roi_out_upper);
    defer texture_upper_out.deinit();

    var bind_group_0_binds_upper_convert: [pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_0_binds_upper_convert[0] = .{ .texture = texture_upper_in };
    bind_group_0_binds_upper_convert[1] = .{ .texture = texture_upper_out };

    var bind_group_upper_convert: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_upper_convert[0] = bind_group_0_binds_upper_convert;

    var bindings_upper = try Bindings.init(&gpu, &convert_compute_pipeline, bind_group_upper_convert);
    defer bindings_upper.deinit();

    // LOWER MEMORY
    var texture_lower_in = try Texture.init(&gpu, "lower_in", layout_group_0_binding_convert[0].?.texture.?.format, roi_in_lower);
    defer texture_lower_in.deinit();

    var texture_lower_out = try Texture.init(&gpu, "lower_out", layout_group_0_binding_convert[1].?.texture.?.format, roi_out_lower);
    defer texture_lower_out.deinit();

    var bind_group_0_binds_lower_convert: [pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_0_binds_lower_convert[0] = .{ .texture = texture_lower_in };
    bind_group_0_binds_lower_convert[1] = .{ .texture = texture_lower_out };

    var bind_group_lower_convert: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_lower_convert[0] = bind_group_0_binds_lower_convert;

    var bindings_lower = try Bindings.init(&gpu, &convert_compute_pipeline, bind_group_lower_convert);
    defer bindings_lower.deinit();

    // PASS 1 | TOP HALF
    encoder.enqueueBufToTex(&upload, upload_offset_upper, &texture_upper_in, roi_in_upper) catch unreachable;
    encoder.enqueueShader(&convert_compute_pipeline, &bindings_upper, roi_out_upper);

    // PASS 2 | BOTTOM HALF
    encoder.enqueueBufToTex(&upload, upload_offset_lower, &texture_lower_in, roi_in_lower) catch unreachable;
    encoder.enqueueShader(&convert_compute_pipeline, &bindings_lower, roi_out_lower);

    // { // EARLY DOWNLOAD TO TEST FORMAT CONVERSION
    //     encoder.enqueueTexToBuf(&download, download_offset_upper, &texture_upper_out, roi_out_upper) catch unreachable;
    //     encoder.enqueueTexToBuf(&download, download_offset_lower, &texture_lower_out, roi_out_lower) catch unreachable;
    //     gpu.run(encoder.finish()) catch unreachable;

    //     // DOWNLOAD
    //     var destination = try allocator.alloc(u8, roi_out.w * roi_out.h * destination_format.bpp());
    //     defer allocator.free(destination);

    //     download.map();
    //     @memcpy(destination[0..download_buf_upper.len], download_buf_upper);
    //     @memcpy(destination[download_buf_upper.len..], download_buf_lower);

    //     // std.debug.print("----- download_buf_upper\n", .{});
    //     // printImgBufContents(u8, download_buf_upper, roi_out.w * 2);
    //     // std.debug.print("----- download_buf_lower\n", .{});
    //     // printImgBufContents(u8, download_buf_lower, roi_out.w * 2);
    //     // std.debug.print("-----\n", .{});

    //     download.unmap();

    //     std.log.info("\nDownload buffer contents: ", .{});
    //     // printImgBufContents(u8, destination, roi_out.w * 4);
    //     printImgBufContents(u8, destination, roi_out.w * 2);
    //     if (true) {
    //         return error.SkipZigTest;
    //     }
    // }

    // roi_out_upper = roi_in_upper.scaled(2, 0.5); // works
    // roi_out_lower = roi_in_lower.scaled(2, 0.5); // works
    roi_out = pie.engine.ROI.full(image_size_in_w, image_size_in_h).div(2, 2);
    roi_out_upper, roi_out_lower = roi_out.splitH();

    // DEMOSAIC WITH COMPUTE SHADER
    // const demosaic_packed: []const u8 =
    //     \\enable f16;
    //     \\@group(0) @binding(0) var input:  texture_2d<f32>;
    //     \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
    //     \\@compute @workgroup_size(8, 8, 1)
    //     \\fn demosaic_packed(@builtin(global_invocation_id) global_id: vec3<u32>) {
    //     \\    var coords = vec2<i32>(global_id.xy);
    //     \\    // INPUT
    //     \\    // libraw outputs the raw data as a 1D buffer, but we will interpret it
    //     \\    // as a single channel 2D texture with a stride of raw_width
    //     \\    // [ (r)g r g r g r g  ...
    //     \\    //    g(b)g b g b g b ...
    //     \\    //    r g r g r g r g  ...
    //     \\    //    g b g b g b g b  ... ]
    //     \\    // iw,ih == raw_width, raw_height
    //     \\    // when we index this texture, we will get
    //     \\    // (0,0) -> [ r ]  // wrong
    //     \\    // (1,1) -> [ b ]  // wrong
    //     \\    //
    //     \\    // we want the mosaic
    //     \\    // [  /r g\ r g  r g  r g ...
    //     \\    //    \g b/ g b  g b  g b ...
    //     \\    //     r g /r g\ r g  r g ...
    //     \\    //     g b \g b/ g b  g b ... ]
    //     \\    //  w,h  =  raw_width/2, raw_height/2
    //     \\    // so that an invocation coord of
    //     \\    // (0,0) -> [ r g g b ]
    //     \\    // (1,1) -> [ r g g b ]
    //     \\    //
    //     \\    // OUTPUT
    //     \\    // we want pixels to be reconstructed as:
    //     \\    // [ [(r g b 1)] [ r g b 1 ] ...
    //     \\    //   [ r g b 1 ] [(r g b 1)] ...
    //     \\    //   [ r g b 1 ] [ r g b 1 ] ...
    //     \\    //   [ r g b 1 ] [ r g b 1 ] ... ]
    //     \\    // ow,oh == raw_width/2, raw_height/2
    //     \\    // (0,0) -> [ r g b 1 ]  // correct
    //     \\    // (1,1) -> [ r g b 1 ]  // correct
    //     \\    //
    //     \\    // DECODE
    //     \\    var r: f32;
    //     \\    var g1: f32;
    //     \\    var g2: f32;
    //     \\    var b: f32;
    //     \\    let base_coords_x: i32 = coords.x * 2; // integer division
    //     \\    let base_coords_y: i32 = coords.y * 2;
    //     \\    r = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0);
    //     \\    g1 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0);
    //     \\    g2 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0);
    //     \\    b = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0);
    //     \\    let g = (g1 + g2) / 2.0;
    //     \\    let rgba = vec4<f32>(r, g, b, 1);
    //     \\    textureStore(output, coords, rgba);
    //     \\}
    // ;
    // THIS IS A WORKAROUND
    const demosaic_packed: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn demosaic_packed(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    // INPUT
        \\    // libraw outputs the raw data as a 1D buffer, but we interpret it as a 2D texture
        \\    // [ [(r g r g)] [ r g r g ] ...
        \\    //   [ g b g b ] [(g b g b)] ...
        \\    //   [ r g r g ] [ r g r g ] ...
        \\    //   [ g b g b ] [ g b g b ] ... ]
        \\    // iw,ih == raw_width/4, raw_height
        \\    // when we index this texture, we will get
        \\    // (0,0) -> [ r g r g ]  // wrong
        \\    // (1,1) -> [ g b g b ]  // wrong
        \\    //
        \\    // we want the mosaic
        \\    // [  /r g\ r g  r g  r g ...
        \\    //    \g b/ g b  g b  g b ...
        \\    //     r g /r g\ r g  r g ...
        \\    //     g b \g b/ g b  g b ... ]
        \\    //  w,h  =  raw_width/2, raw_height/2
        \\    // so that an invocation coord of
        \\    // (0,0) -> [ r g g b ]
        \\    // (1,1) -> [ r g g b ]
        \\    //
        \\    // OUTPUT
        \\    // we want pixels to be reconstructed as:
        \\    // [ [(r g b 1)] [ r g b 1 ] ...
        \\    //   [ r g b 1 ] [(r g b 1)] ...
        \\    //   [ r g b 1 ] [ r g b 1 ] ...
        \\    //   [ r g b 1 ] [ r g b 1 ] ... ]
        \\    // ow,oh == raw_width/2, raw_height/2
        \\    // (0,0) -> [ r g b 1 ]  // correct
        \\    // (1,1) -> [ r g b 1 ]  // correct
        \\    //
        \\    // DECODE
        \\    var r: f32;
        \\    var g1: f32;
        \\    var g2: f32;
        \\    var b: f32;
        \\    let base_coords_x: i32 = coords.x / 2; // integer division
        \\    let base_coords_y: i32 = coords.y * 2;
        \\    let is_even_x = (coords.x % 2) == 0;
        \\    if (is_even_x) {
        \\        r = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).r;
        \\        g1 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).g;
        \\        g2 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).r;
        \\        b = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).g;
        \\    } else {
        \\        r = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).b;
        \\        g1 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).a;
        \\        g2 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).b;
        \\        b = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).a;
        \\    }
        \\    let g = (g1 + g2) / 2.0;
        \\    let rgba = vec4<f32>(r, g, b, 1);
        \\    textureStore(output, coords, rgba);
        \\}
    ;
    var shader_demosaic = try Shader.compile(&gpu, demosaic_packed, .{});
    defer shader_demosaic.deinit();

    var layout_group_0_binding: [pie.engine.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group_0_binding[0] = .{ .texture = .{ .access = .read, .format = .rgba16float } };
    layout_group_0_binding[1] = .{ .texture = .{ .access = .write, .format = .rgba16float } };

    var layout_group: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupLayoutEntry = @splat(null);
    layout_group[0] = layout_group_0_binding;
    var demosaic_compute_pipeline = try ComputePipeline.init(&gpu, shader_demosaic, "demosaic_packed", layout_group);
    defer demosaic_compute_pipeline.deinit();

    // UPPER MEMORY
    const texture_upper_in2 = texture_upper_out; // reuse the output of the format conversion
    // var texture_upper_in2 = try Texture.init(&gpu, demosaic_conns[0].format, roi_in_upper);
    // defer texture_upper_in2.deinit();
    // gpu.enqueueCopyTextureToTexture(&texture_upper_out, &texture_upper_in2, roi_in_upper) catch unreachable;

    var texture_upper_out2 = try Texture.init(&gpu, "upper_out2", layout_group_0_binding[1].?.texture.?.format, roi_out_upper);
    defer texture_upper_out2.deinit();

    var bind_group_0_binds_upper: [pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_0_binds_upper[0] = .{ .texture = texture_upper_in2 };
    bind_group_0_binds_upper[1] = .{ .texture = texture_upper_out2 };

    var bind_group_upper: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_upper[0] = bind_group_0_binds_upper;

    bindings_upper = try Bindings.init(&gpu, &demosaic_compute_pipeline, bind_group_upper);
    defer bindings_upper.deinit();

    // LOWER MEMORY
    const texture_lower_in2 = texture_lower_out; // reuse the output of the format conversion
    // var texture_lower_in2 = try Texture.init(&gpu, demosaic_conns[0].format, roi_in_lower);
    // defer texture_lower_in2.deinit();
    // gpu.enqueueCopyTextureToTexture(&texture_lower_out, &texture_lower_in2, roi_in_lower) catch unreachable;

    var texture_lower_out2 = try Texture.init(&gpu, "lower_out2", layout_group_0_binding[1].?.texture.?.format, roi_out_lower);
    defer texture_lower_out2.deinit();

    var bind_group_0_binds_lower: [pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_0_binds_lower[0] = .{ .texture = texture_lower_in2 };
    bind_group_0_binds_lower[1] = .{ .texture = texture_lower_out2 };

    var bind_group_lower: [pie.engine.gpu.MAX_BIND_GROUPS]?[pie.engine.gpu.MAX_BINDINGS]?BindGroupEntry = @splat(null);
    bind_group_lower[0] = bind_group_0_binds_lower;

    bindings_lower = try Bindings.init(&gpu, &demosaic_compute_pipeline, bind_group_lower);
    defer bindings_lower.deinit();

    // copy from last step
    // We are going to do two passes as if the hardware buffer does not allow a full image to be copied to a texture at once

    // PASS 1 | TOP HALF
    encoder.enqueueShader(&demosaic_compute_pipeline, &bindings_upper, roi_out_upper);
    // PASS 2 | BOTTOM HALF
    encoder.enqueueShader(&demosaic_compute_pipeline, &bindings_lower, roi_out_lower);

    encoder.enqueueTexToBuf(&download, download_offset_upper, &texture_upper_out2, roi_out_upper) catch unreachable;
    encoder.enqueueTexToBuf(&download, download_offset_lower, &texture_lower_out2, roi_out_lower) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    var destination = try allocator.alloc(f16, roi_out.w * roi_out.h * destination_format.nchannels());
    defer allocator.free(destination);

    download.map();
    @memcpy(destination[0..download_buf_upper.len], @as([*]f16, @ptrCast(@alignCast(download_buf_upper))));
    @memcpy(destination[download_buf_upper.len..], @as([*]f16, @ptrCast(@alignCast(download_buf_lower))));
    download.unmap();

    std.log.info("\nDownload buffer contents: ", .{});
    printImgBufContents(f16, destination, roi_out.w * 4);

    // EXPORT PNG
    {
        // convert f16 slice to f32 slice
        std.log.info("Casting f16 to f32", .{});
        const output_slice = try allocator.alloc(f32, destination.len);
        defer allocator.free(output_slice);
        for (destination, 0..) |value, i| {
            output_slice[i] = @as(f32, value);
        }

        std.log.info("Casting to bytes", .{});
        const byte_array2 = std.mem.sliceAsBytes(output_slice);

        std.log.info("Giving to zigimg", .{});
        var zigimage2 = try zigimg.Image.fromRawPixels(allocator, roi_out.w, roi_out.h, byte_array2[0..], .float32);
        defer zigimage2.deinit(allocator);

        try zigimage2.convert(allocator, .rgba64);
        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zigimage2.writeToFilePath(allocator, "testing/images/DSC_6765_debayered.png", write_buffer2[0..], .{ .png = .{} });
    }
}
