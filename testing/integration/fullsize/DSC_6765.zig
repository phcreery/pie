const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

fn printImgBufContents(ibuf: []f16, stride: u32) void {
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

    // call the internal raw2image to populate libraw_rp.image with the expanded RGGB data
    const ret3 = libraw.libraw_raw2image(pie_raw_image.libraw_rp);
    if (ret3 != libraw.LIBRAW_SUCCESS) {
        std.log.info("libraw_raw2image failed: {d}", .{ret3});
        try std.testing.expect(false);
        return;
    }
    std.log.info("libraw_raw2image succeeded", .{});

    const raw2image_image = pie_raw_image.libraw_rp.image;

    const stride = @as(u32, @intCast(pie_raw_image.width)) * 4;
    std.log.info("Image stride (channels): {d}", .{stride});

    std.log.info("Casting u16 to f16 and Normalizing", .{});
    const init_contents_f16 = try allocator.alloc(f16, @as(u32, @intCast(pie_raw_image.width * 2)) * pie_raw_image.height * 2);
    defer allocator.free(init_contents_f16);

    for (0..pie_raw_image.height) |y| {
        for (0..pie_raw_image.width) |x| {
            for (0..4) |ch| {
                const iindex = y * pie_raw_image.width + x;
                const oindex = (y * pie_raw_image.width) * 4 + x * 4 + ch;
                if (raw2image_image[iindex][ch] == 0) {
                    init_contents_f16[oindex] = 0.0;
                } else {
                    init_contents_f16[oindex] = @as(f16, @floatFromInt(raw2image_image[iindex][ch])) / pie_raw_image.max_value;
                }
                if (oindex < 16 or (oindex >= stride * 1 and oindex < stride * 1 + 16)) {
                    std.debug.print("Pixel ({d}, {d}) channel {d}: raw {d}, raw2image {d}, float {d}\n", .{
                        x,
                        y,
                        ch,
                        pie_raw_image.raw_image[iindex],
                        raw2image_image[iindex][ch],
                        init_contents_f16[oindex],
                    });
                }
            }
        }
    }

    std.log.info("Initial contents length (pixels): {d}", .{init_contents_f16.len});

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

    var gpu = try pie.engine.gpu.GPU.init();
    defer gpu.deinit();

    // FORMAT CONVERSION WITH COMPUTE SHADER
    const format: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d;
        \\@group(0) @binding(1) var output: texture_storage_2d<write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn format(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    let px = textureLoad(input, coords, 0);
        \\    textureStore(output, coords, px);
        \\}
    ;
    var format_shader_pipe = try pie.engine.gpu.ShaderPipe.init(&gpu, format, "format");
    defer format_shader_pipe.deinit();

    // DEMOSAIC WITH COMPUTE SHADER
    const demosaic: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn demosaic(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    // the input will not be stored as rgba, instead it will be
        \\    // [ r 0 0 0 ] [ 0 g 0 0 ] ...
        \\    // [ 0 g 0 0 ] [ 0 0 b 0 ] ...
        \\    // [ r 0 0 0 ] [ 0 g 0 0 ] ...
        \\    // [ 0 g 0 0 ] [ 0 0 b 0 ] ...
        \\    // so we need to decode our coords
        \\    var r: f32;
        \\    var g1: f32;
        \\    var g2: f32;
        \\    var b: f32;
        \\    let base_coords = coords * vec2<i32>(2, 2);
        \\    r = textureLoad(input, base_coords + vec2<i32>(0, 0), 0).r;
        \\    g1 = textureLoad(input, base_coords + vec2<i32>(1, 0), 0).g;
        \\    g2 = textureLoad(input, base_coords + vec2<i32>(0, 1), 0).a;
        \\    b = textureLoad(input, base_coords + vec2<i32>(1, 1), 0).b;
        \\    let g = (g1 + g2) / 2.0;
        \\    let rgba = vec4f(r, g, b, 1);
        \\    textureStore(output, coords, rgba);
        \\}
    ;
    var demosaic_shader_pipe = try pie.engine.gpu.ShaderPipe.init(&gpu, demosaic, "demosaic");
    defer demosaic_shader_pipe.deinit();

    // UPPER MEMORY
    var texture_upper_in = try pie.engine.gpu.Texture.init(&gpu);
    defer texture_upper_in.deinit();

    var texture_upper_out = try pie.engine.gpu.Texture.init(&gpu);
    defer texture_upper_out.deinit();

    var bindings_upper = try pie.engine.gpu.Bindings.init(&gpu, &demosaic_shader_pipe, &texture_upper_in, &texture_upper_out);
    defer bindings_upper.deinit();

    // LOWER MEMORY
    var texture_lower_in = try pie.engine.gpu.Texture.init(&gpu);
    defer texture_lower_in.deinit();

    var texture_lower_out = try pie.engine.gpu.Texture.init(&gpu);
    defer texture_lower_out.deinit();

    var bindings_lower = try pie.engine.gpu.Bindings.init(&gpu, &demosaic_shader_pipe, &texture_lower_in, &texture_lower_out);
    defer bindings_lower.deinit();

    // SIZES
    const image_size_in_w = @as(u32, @intCast(pie_raw_image.width));
    const image_size_in_h = @as(u32, @intCast(pie_raw_image.height));

    const roi_in = pie.engine.ROI.full(image_size_in_w, image_size_in_h);
    const roi_out = roi_in.scaled(0.5, 0.5);
    const roi_in_upper, const roi_in_lower = roi_in.splitH();
    const roi_out_upper, const roi_out_lower = roi_out.splitH();

    std.log.info("Image region: {any} {any}", .{ roi_in.size.w, roi_in.size.h });
    // std.log.info("Image region after: {any} {any}", .{image_size_out_w, image_size_out_h});

    std.log.info("\nUpload buffer contents: ", .{});
    printImgBufContents(init_contents_f16, roi_in.size.w * 4);

    gpu.mapUpload(init_contents_f16, roi_in);

    // We are going to do two passes as if the hardware buffer does not allow a full image to be copied to a texture at once

    // PASS 1 | TOP HALF
    gpu.enqueueMount(&texture_upper_in, roi_in_upper) catch unreachable;
    gpu.enqueueShader(&demosaic_shader_pipe, &bindings_upper, roi_out_upper);
    gpu.enqueueUnmount(&texture_upper_out, roi_out_upper) catch unreachable;
    // PASS 2 | BOTTOM HALF
    gpu.enqueueMount(&texture_lower_in, roi_in_lower) catch unreachable;
    gpu.enqueueShader(&demosaic_shader_pipe, &bindings_lower, roi_out_lower);
    gpu.enqueueUnmount(&texture_lower_out, roi_out_lower) catch unreachable;

    gpu.run();

    const result = try gpu.mapDownload(roi_out);

    std.log.info("\nDownload buffer contents: ", .{});
    printImgBufContents(result, roi_out.size.w * 4);

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
        var zigimage2 = try zigimg.Image.fromRawPixels(allocator, roi_out.size.w, roi_out.size.h, byte_array2[0..], .float32);
        defer zigimage2.deinit(allocator);

        try zigimage2.convert(allocator, .rgba64);
        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zigimage2.writeToFilePath(allocator, "testing/integration/fullsize/DSC_6765_debayered.png", write_buffer2[0..], .{ .png = .{} });
    }
}
