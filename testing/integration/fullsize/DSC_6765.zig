const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

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
    const file_name = "testing/integration/fullsize/DSC_6765.NEF";
    const file = try std.fs.cwd().openFile(file_name, .{});
    var pie_raw_image = try pie.iraw.RawImage.read(allocator, file);
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
    //     try zigimage.writeToFilePath(allocator, "testing/integration/fullsize/DSC_6765.png", write_buffer[0..], .{ .png = .{} });
    // }

    // // EXPORT RAW
    // {
    //     // 1. Open or create the file
    //     var file_raw = try std.fs.cwd().createFile("testing/integration/fullsize/DSC_6765.raw", .{ .read = true });
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

    var roi_in = pie.engine.ROI.full(image_size_in_w, image_size_in_h);
    roi_in = roi_in.div(4, 1); // we have 1/4 width input (packed RGGB)

    var roi_out = roi_in;
    const roi_in_upper, const roi_in_lower = roi_in.splitH();
    var roi_out_upper, var roi_out_lower = roi_out.splitH();

    var gpu = try pie.engine.gpu.GPU.init();
    defer gpu.deinit();

    var gpu_allocator = try pie.engine.gpu.Buffer.init(&gpu, null);
    defer gpu_allocator.deinit();

    // UPLOAD
    std.log.info("Image region: {any} {any}", .{ roi_in.w, roi_in.h });
    std.log.info("Upload buffer contents: ", .{});
    printImgBufContents(u16, init_contents_u16, roi_in.w * 2);

    gpu_allocator.upload(u16, init_contents_u16, .rgba16uint, roi_in);

    var encoder = try pie.engine.gpu.Encoder.start(&gpu);
    defer encoder.deinit();

    // FORMAT CONVERSION WITH COMPUTE SHADER
    const convert: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<u32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn convert(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    let px = textureLoad(input, coords, 0);
        \\    //let pxf = bitcast<vec4<f32>>(px); // does not work
        \\    //let pxf = vec4<f32>(1.0,2.0,3.0,4.0); // for testing
        \\    let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a)) / 4096.0; // max_value
        \\    textureStore(output, coords, pxf);
        \\}
    ;
    const convert_conns = [_]pie.engine.gpu.ShaderPipeConn{ .{
        .binding = 0,
        .type = .input,
        .format = .rgba16uint,
    }, .{
        .binding = 1,
        .type = .output,
        .format = .rgba16float,
    } };
    var convert_shader_pipe = try pie.engine.gpu.ShaderPipe.init(&gpu, convert, "convert", convert_conns);
    defer convert_shader_pipe.deinit();

    // UPPER MEMORY
    var texture_upper_in = try pie.engine.gpu.Texture.init(&gpu, convert_conns[0].format, roi_in_upper);
    defer texture_upper_in.deinit();

    var texture_upper_out = try pie.engine.gpu.Texture.init(&gpu, convert_conns[1].format, roi_out_upper);
    defer texture_upper_out.deinit();

    var bindings_upper = try pie.engine.gpu.Bindings.init(&gpu, &convert_shader_pipe, &texture_upper_in, &texture_upper_out);
    defer bindings_upper.deinit();

    // LOWER MEMORY
    var texture_lower_in = try pie.engine.gpu.Texture.init(&gpu, convert_conns[0].format, roi_in_lower);
    defer texture_lower_in.deinit();

    var texture_lower_out = try pie.engine.gpu.Texture.init(&gpu, convert_conns[1].format, roi_out_lower);
    defer texture_lower_out.deinit();

    var bindings_lower = try pie.engine.gpu.Bindings.init(&gpu, &convert_shader_pipe, &texture_lower_in, &texture_lower_out);
    defer bindings_lower.deinit();

    encoder.enqueueBufToTex(&gpu_allocator, &texture_upper_in, roi_in_upper) catch unreachable;
    encoder.enqueueBufToTex(&gpu_allocator, &texture_lower_in, roi_in_lower) catch unreachable;

    // PASS 1 | TOP HALF
    encoder.enqueueShader(&convert_shader_pipe, &bindings_upper, roi_out_upper);
    // PASS 2 | BOTTOM HALF
    encoder.enqueueShader(&convert_shader_pipe, &bindings_lower, roi_out_lower);

    // { // early exit after conversion
    //     gpu.enqueueUnmount(&texture_upper_out, convert_conns[1].format, roi_out_upper) catch unreachable;
    //     gpu.enqueueUnmount(&texture_lower_out, convert_conns[1].format, roi_out_lower) catch unreachable;
    //     gpu.run();
    //     const result_convert = try gpu.mapDownload(f16, convert_conns[1].format, roi_out_lower);
    //     std.log.info("\nDownload buffer contents: ", .{});
    //     printImgBufContents(f16, result_convert, roi_out_lower.w * 2);
    //     if (true) {
    //         return error.SkipZigTest;
    //     }
    // }

    roi_out_upper = roi_in_upper.scaled(2, 0.5); // works
    roi_out_lower = roi_in_lower.scaled(2, 0.5); // works
    roi_out = pie.engine.ROI.full(image_size_in_w, image_size_in_h).div(2, 2);

    // DEMOSAIC WITH COMPUTE SHADER
    // const demosaic: []const u8 =
    //     \\enable f16;
    //     \\@group(0) @binding(0) var input:  texture_2d<f32>;
    //     \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
    //     \\@compute @workgroup_size(8, 8, 1)
    //     \\fn demosaic(@builtin(global_invocation_id) global_id: vec3<u32>) {
    //     \\    var coords = vec2<i32>(global_id.xy);
    //     \\    // the input will not be stored as rgba, instead it will be
    //     \\    // [ r 0 0 0 ] [ 0 g 0 0 ] ...
    //     \\    // [ 0 g 0 0 ] [ 0 0 b 0 ] ...
    //     \\    // [ r 0 0 0 ] [ 0 g 0 0 ] ...
    //     \\    // [ 0 g 0 0 ] [ 0 0 b 0 ] ...
    //     \\    // so we need to decode our coords
    //     \\    var r: f32;
    //     \\    var g1: f32;
    //     \\    var g2: f32;
    //     \\    var b: f32;
    //     \\    let base_coords = coords * vec2<i32>(2, 2);
    //     \\    r = textureLoad(input, base_coords + vec2<i32>(0, 0), 0).r;
    //     \\    g1 = textureLoad(input, base_coords + vec2<i32>(1, 0), 0).g;
    //     \\    g2 = textureLoad(input, base_coords + vec2<i32>(0, 1), 0).a;
    //     \\    b = textureLoad(input, base_coords + vec2<i32>(1, 1), 0).b;
    //     \\    let g = (g1 + g2) / 2.0;
    //     \\    let rgba = vec4<f32>(r, g, b, 1);
    //     \\    textureStore(output, coords, rgba);
    //     \\}
    // ;
    // const demosaic_conns = [_]pie.engine.gpu.ShaderPipeConn{ .{
    //     .binding = 0,
    //     .type = .input,
    //     .format = .rgba16float,
    // }, .{
    //     .binding = 1,
    //     .type = .output,
    //     .format = .rgba16float,
    // } };

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
    const demosaic_conns = [_]pie.engine.gpu.ShaderPipeConn{ .{
        .binding = 0,
        .type = .input,
        .format = .rgba16float,
    }, .{
        .binding = 1,
        .type = .output,
        .format = .rgba16float,
    } };
    var demosaic_shader_pipe = try pie.engine.gpu.ShaderPipe.init(&gpu, demosaic_packed, "demosaic_packed", demosaic_conns);
    defer demosaic_shader_pipe.deinit();

    // UPPER MEMORY
    var texture_upper_in2 = texture_upper_out; // reuse the output of the format conversion
    // var texture_upper_in2 = try pie.engine.gpu.Texture.init(&gpu, demosaic_conns[0].format, roi_in_upper);
    // defer texture_upper_in2.deinit();
    // gpu.enqueueCopyTextureToTexture(&texture_upper_out, &texture_upper_in2, roi_in_upper) catch unreachable;

    var texture_upper_out2 = try pie.engine.gpu.Texture.init(&gpu, demosaic_conns[1].format, roi_out_upper);
    defer texture_upper_out2.deinit();

    bindings_upper = try pie.engine.gpu.Bindings.init(&gpu, &demosaic_shader_pipe, &texture_upper_in2, &texture_upper_out2);
    defer bindings_upper.deinit();

    // LOWER MEMORY
    var texture_lower_in2 = texture_lower_out; // reuse the output of the format conversion
    // var texture_lower_in2 = try pie.engine.gpu.Texture.init(&gpu, demosaic_conns[0].format, roi_in_lower);
    // defer texture_lower_in2.deinit();
    // gpu.enqueueCopyTextureToTexture(&texture_lower_out, &texture_lower_in2, roi_in_lower) catch unreachable;

    var texture_lower_out2 = try pie.engine.gpu.Texture.init(&gpu, demosaic_conns[1].format, roi_out_lower);
    defer texture_lower_out2.deinit();

    bindings_lower = try pie.engine.gpu.Bindings.init(&gpu, &demosaic_shader_pipe, &texture_lower_in2, &texture_lower_out2);
    defer bindings_lower.deinit();

    // copy from last step
    // We are going to do two passes as if the hardware buffer does not allow a full image to be copied to a texture at once

    // PASS 1 | TOP HALF
    encoder.enqueueShader(&demosaic_shader_pipe, &bindings_upper, roi_out_upper);
    // PASS 2 | BOTTOM HALF
    encoder.enqueueShader(&demosaic_shader_pipe, &bindings_lower, roi_out_lower);

    encoder.enqueueTexToBuf(&gpu_allocator, &texture_upper_out2, roi_out_upper) catch unreachable;
    encoder.enqueueTexToBuf(&gpu_allocator, &texture_lower_out2, roi_out_lower) catch unreachable;
    gpu.run(encoder.finish()) catch unreachable;

    // DOWNLOAD
    const result = try gpu_allocator.download(f16, .rgba16float, roi_out);

    std.log.info("\nDownload buffer contents: ", .{});
    printImgBufContents(f16, result, roi_out.w * 4);

    // EXPORT PNG
    {
        // convert f16 slice to f32 slice
        std.log.info("Casting f16 to f32", .{});
        const output_slice = try allocator.alloc(f32, result.len);
        defer allocator.free(output_slice);
        for (result, 0..) |value, i| {
            output_slice[i] = @as(f32, value);
        }

        std.log.info("Casting to bytes", .{});
        const byte_array2 = std.mem.sliceAsBytes(output_slice);

        std.log.info("Giving to zigimg", .{});
        var zigimage2 = try zigimg.Image.fromRawPixels(allocator, roi_out.w, roi_out.h, byte_array2[0..], .float32);
        defer zigimage2.deinit(allocator);

        try zigimage2.convert(allocator, .rgba64);
        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zigimage2.writeToFilePath(allocator, "testing/integration/fullsize/DSC_6765_debayered.png", write_buffer2[0..], .{ .png = .{} });
    }
}
