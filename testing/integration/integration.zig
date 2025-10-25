const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

pub fn main() !void {
    std.log.info("Starting Integration tests", .{});
}

test {
    _ = @import("engine.zig");
}

test "load raw, debayer, save" {
    // if (true) {
    //     return error.SkipZigTest;
    // }
    const allocator = std.testing.allocator;

    // Read contents from file
    const file_name = "testing/integration/DSC_6765.NEF";
    const file = try std.fs.cwd().openFile(file_name, .{});
    var pie_raw_image = try pie.iraw.RawImage.read(allocator, file);
    defer pie_raw_image.deinit();

    const ret3 = libraw.libraw_raw2image(pie_raw_image.libraw_rp);
    if (ret3 != libraw.LIBRAW_SUCCESS) {
        std.log.info("libraw_raw2image failed: {d}", .{ret3});
        try std.testing.expect(false);
        return;
    }
    std.log.info("libraw_raw2image succeeded", .{});

    // const raw_image = pie_raw_image.libraw_rp.rawdata.raw_image;
    const raw2image_image = pie_raw_image.libraw_rp.image;
    // pie_raw_image.libraw_rp
    // const img_width = pie_raw_image.libraw_rp.sizes.width;
    // const img_height = pie_raw_image.libraw_rp.sizes.height;
    // const max_value: u32 = pie_raw_image.libraw_rp.rawdata.color.maximum;

    // std.debug.print("Raw Image first pixels\n", .{});
    // for (raw_image[0..16]) |p| {
    //     std.debug.print("{d} ", .{p});
    // }
    // std.debug.print("\n\n", .{});

    // std.debug.print("raw2image Image first pixels\n", .{});
    // for (raw2image_image[0..16]) |p| {
    //     std.debug.print("{d} {d} {d} {d}, \n", .{ p[0], p[1], p[2], p[3] });
    // }
    // std.debug.print("\n\n", .{});

    const stride = @as(u32, @intCast(pie_raw_image.width)) * 4;
    std.log.info("Image stride (pixels): {d}", .{stride});

    std.log.info("Casting u16 to f16 and Normalizing", .{});
    const init_contents_f16 = try allocator.alloc(f16, @as(u32, @intCast(pie_raw_image.width * 2)) * pie_raw_image.height * 2);
    defer allocator.free(init_contents_f16);

    for (0..pie_raw_image.height) |y| {
        for (0..pie_raw_image.width) |x| {
            for (0..4) |ch| {
                const iindex = y * pie_raw_image.width + x;
                const oindex = (y * pie_raw_image.width) * 4 + x * 4 + ch;
                // if (ch == 3) {
                // alpha channel
                // init_contents_f16[oindex] = 1.0;
                // continue;
                // g2
                // init_contents_f16[oindex - 2] = @as(f16, @floatFromInt(raw2image_image[iindex][ch])) / pie_raw_image.max_value;
                // }
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

    // const init_contents_f16 = pie_raw_image.raw_image;
    // const init_contents_f16 = raw2image_image;

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
    //     try zigimage.writeToFilePath(allocator, "testing/integration/DSC_6765.png", write_buffer[0..], .{ .png = .{} });
    // }

    // // EXPORT RAW
    // {
    //     // 1. Open or create the file
    //     var file_raw = try std.fs.cwd().createFile("testing/integration/DSC_6765.raw", .{ .read = true });
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

    // DEBAYER WITH COMPUTE SHADER

    var gpu = try pie.gpu.GPU.init();
    defer gpu.deinit();

    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn debayer(@builtin(global_invocation_id) global_id: vec3<u32>) {
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
        \\    let rgba = vec4f(r, g, b, f32(coords.y)); // just to see some variation in alpha
        \\    textureStore(output, coords, rgba);
        \\}
    ;
    var shader_pipe = try pie.gpu.ShaderPipe.init(&gpu, shader_code, "debayer");
    defer shader_pipe.deinit();

    // UPPER MEMORY
    var texture_upper_in = try pie.gpu.Texture.init(&gpu);
    defer texture_upper_in.deinit();

    var texture_upper_out = try pie.gpu.Texture.init(&gpu);
    defer texture_upper_out.deinit();

    var bindings_upper = try pie.gpu.Bindings.init(&gpu, &shader_pipe, &texture_upper_in, &texture_upper_out);
    defer bindings_upper.deinit();

    // LOWER MEMORY
    var texture_lower_in = try pie.gpu.Texture.init(&gpu);
    defer texture_lower_in.deinit();

    var texture_lower_out = try pie.gpu.Texture.init(&gpu);
    defer texture_lower_out.deinit();

    var bindings_lower = try pie.gpu.Bindings.init(&gpu, &shader_pipe, &texture_lower_in, &texture_lower_out);
    defer bindings_lower.deinit();

    // SIZES
    const image_size_in_w = @as(u32, @intCast(pie_raw_image.width));
    const image_size_in_h = @as(u32, @intCast(pie_raw_image.height));
    const image_size_out_w = image_size_in_w / 2;
    const image_size_out_h = image_size_in_h / 2;

    const roi_in = pie.gpu.StageROI{
        .size = .{
            .w = image_size_in_w,
            .h = image_size_in_h,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };
    const roi_out = pie.gpu.StageROI{
        .size = .{
            .w = image_size_in_w / 2,
            .h = image_size_in_h / 2,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };
    const roi_top_in = pie.gpu.StageROI{
        .size = .{
            .w = image_size_in_w,
            .h = image_size_in_h / 2,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };
    const roi_top_out = pie.gpu.StageROI{
        .size = .{
            .w = image_size_in_w / 2,
            .h = image_size_in_h / 4,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };
    const roi_bottom_in = pie.gpu.StageROI{
        .size = .{
            .w = image_size_in_w,
            .h = image_size_in_h / 2,
        },
        .origin = .{
            .x = 0,
            .y = image_size_in_h / 2,
        },
    };
    const roi_bottom_out = pie.gpu.StageROI{
        .size = .{
            .w = image_size_in_w / 2,
            .h = image_size_in_h / 4,
        },
        .origin = .{
            .x = 0,
            .y = image_size_in_h / 4,
        },
    };

    std.log.info("Image region: {any} {any}", .{ image_size_in_w, image_size_in_h });
    // std.log.info("Image region after: {any} {any}", .{image_size_out_w, image_size_out_h});

    std.log.info("\nUpload buffer contents: ", .{});
    std.debug.print("{any}...\n", .{init_contents_f16[0..8]});
    std.debug.print("{any}...\n", .{init_contents_f16[image_size_in_w .. image_size_in_w + 8]});
    std.debug.print("{any}...\n", .{init_contents_f16[image_size_in_w * 2 .. image_size_in_w * 2 + 8]});
    std.debug.print("{any}...\n", .{init_contents_f16[image_size_in_w * 3 .. image_size_in_w * 3 + 8]});
    std.debug.print("...\n", .{});
    // std.debug.print("{any}...\n", .{init_contents_f16[image_size_init.w * (image_size_init.h - 1) .. image_size_init.w * (image_size_init.h - 1) + 8]});
    std.debug.print("...{any}\n", .{init_contents_f16[init_contents_f16.len - 8 .. init_contents_f16.len]});

    gpu.mapUpload(init_contents_f16, roi_in);

    // We are going to do two passes as if the hardware buffer does not allow a full image to be copied to a texture at once

    // PASS 1 | TOP HALF
    gpu.enqueueStage(&texture_upper_in, roi_top_in) catch unreachable;
    gpu.enqueueShader(&shader_pipe, &bindings_upper, roi_top_out);
    gpu.enqueueDestage(&texture_upper_out, roi_top_out) catch unreachable;
    // PASS 2 | BOTTOM HALF
    gpu.enqueueStage(&texture_lower_in, roi_bottom_in) catch unreachable;
    gpu.enqueueShader(&shader_pipe, &bindings_lower, roi_bottom_out);
    gpu.enqueueDestage(&texture_lower_out, roi_bottom_out) catch unreachable;

    gpu.run();

    const result = try gpu.mapDownload(roi_out);
    std.log.info("\nDownload buffer contents: ", .{});
    std.debug.print("{any}...\n", .{result[0..8]});
    std.debug.print("{any}...\n", .{result[image_size_out_w .. image_size_out_w + 8]});
    std.debug.print("{any}...\n", .{result[image_size_out_w * 2 .. image_size_out_w * 2 + 8]});
    std.debug.print("{any}...\n", .{result[image_size_out_w * 3 .. image_size_out_w * 3 + 8]});
    std.debug.print("...\n", .{});
    // std.debug.print("{any}...\n", .{result[image_size_after.w * (image_size_after.h - 1) .. image_size_after.w * (image_size_after.h - 1) + 8]});
    std.debug.print("...{any}\n", .{result[result.len - 8 .. result.len]});

    var lowest_gt1: f16 = 99999.0;
    var highest_gt1: f16 = 0.0;
    // find non-zero values of result
    for (result) |value| {
        // if (value != 0.0) {
        //     std.log.info("Result non-zero at index {d}: {d}", .{ i, value });
        // }
        if (value > 1.0) {
            lowest_gt1 = @min(lowest_gt1, value);
            highest_gt1 = @max(highest_gt1, value);
        }
    }
    std.log.info("Lowest value > 1.0: {d}", .{lowest_gt1});
    std.log.info("Highest value > 1.0: {d}", .{highest_gt1});

    // Calculate the size in bytes
    std.log.info("Result length (pixels): {d}", .{result.len});
    // std.log.info("Type of my_int: {any}", .{@TypeOf(result[0])});

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
        var zigimage2 = try zigimg.Image.fromRawPixels(allocator, image_size_out_w, image_size_out_h, byte_array2[0..], .float32);
        defer zigimage2.deinit(allocator);

        // std.log.info("zigimg reads as: {any}", .{zigimage2.pixels.float32[0..8]});
        try zigimage2.convert(allocator, .rgba64);
        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zigimage2.writeToFilePath(allocator, "testing/integration/DSC_6765_debayered.png", write_buffer2[0..], .{ .png = .{} });
    }
}
