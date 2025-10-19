const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

pub fn main() !void {
    std.log.info("Starting Integration tests", .{});
}

// test {
//     _ = @import("engine.zig");
// }

inline fn to_bytes(num: anytype) []const u8 {
    return &@as([@sizeOf(@TypeOf(num))]u8, @bitCast(num));
}

test "libraw open bayer" {
    if (true) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    // Read contents from file
    const file_name = "testing/integration/DSC_6765.NEF";
    std.debug.print("Opening file: {s}\n", .{file_name});
    const file = try std.fs.cwd().openFile(file_name, .{});
    const file_info = try file.stat();
    std.debug.print("File size: {d} bytes\n", .{file_info.size});

    // create buffer and read entire file into it
    var buf: []u8 = try allocator.alloc(u8, file_info.size);
    defer allocator.free(buf);
    const read_size2 = try file.read(buf[0..]);
    std.debug.print("Read {d} bytes from file\n", .{read_size2});
    for (buf[0..4]) |b| {
        std.debug.print("{x} ", .{b});
    }
    std.debug.print("... \n", .{});

    const rp = libraw.libraw_init(0);

    const ret = libraw.libraw_open_buffer(rp, buf.ptr, buf.len);
    // const ret = libraw.libraw_open_file(rp, file_name);
    if (ret != libraw.LIBRAW_SUCCESS) {
        std.debug.print("libraw_open failed: {d}\n", .{ret});
        try std.testing.expect(false);
        return;
    }
    std.debug.print("libraw_open succeeded\n", .{});
    const ret2 = libraw.libraw_unpack(rp);
    if (ret2 != libraw.LIBRAW_SUCCESS) {
        std.debug.print("libraw_unpack failed: {d}\n", .{ret2});
        try std.testing.expect(false);
        return;
    }
    std.debug.print("libraw_unpack succeeded\n", .{});
    const img_width = rp.*.sizes.width;
    const img_height = rp.*.sizes.height;
    try std.testing.expect(img_width == 6016);
    try std.testing.expect(img_height == 4016);
    std.debug.print("Image size: {d}x{d}\n", .{ img_width, img_height });
    std.debug.print("Filters: {x}\n", .{rp.*.rawdata.iparams.filters});
    std.debug.print("Colors: {d}\n", .{rp.*.rawdata.iparams.colors});
    std.debug.print("Color Desc.: {s}\n", .{rp.*.rawdata.iparams.cdesc});
    const raw_image = rp.*.rawdata.raw_image;
    // print first 16 pixels
    for (raw_image[0..16]) |p| {
        std.debug.print("{d} ", .{p});
    }
    std.debug.print("... \n", .{});

    // convert from RGBG to RGGB
    var buf_rggb: []u16 = try allocator.alloc(u16, @as(u32, img_width) * img_height * 4);
    defer allocator.free(buf_rggb);
    for (0..img_height) |y| {
        for (0..img_width) |x| {
            const src_index = y * img_width + x * 4;
            const dst_index = y * img_width + x * 4;
            buf_rggb[dst_index] = raw_image[src_index];
            buf_rggb[dst_index + 1] = raw_image[src_index + 1];
            buf_rggb[dst_index + 2] = raw_image[src_index + 3];
            buf_rggb[dst_index + 3] = raw_image[src_index + 2];
        }
    }
    std.debug.print("First 16 pixels of rggb: \n", .{});
    for (buf_rggb[0..16]) |p| {
        std.debug.print("{d} ", .{p});
    }
    std.debug.print("... \n", .{});
}

test "debayer" {
    if (true) {
        return error.SkipZigTest;
    }
    var engine = try pie.engine.Engine.init();
    defer engine.deinit();

    // https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/shader.wgsl
    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn debayer(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    let r = textureLoad(input, 2 * coords , 0).r;
        \\    let g1 = textureLoad(input, 2 * coords, 0).g;
        \\    let g2 = textureLoad(input, 2 * coords, 0).b;
        \\    let b = textureLoad(input, 2 * coords, 0).a;
        \\    let g = (g1 + g2) / 2.0;
        \\    let rgba = vec4f(r, g, b, 1.0);
        \\    textureStore(output, coords, rgba);
        \\    //textureStore(output, coords, rgba);
        \\}
    ;
    var shader_pipe = try engine.compileShader(shader_code, "debayer");
    defer shader_pipe.deinit();

    const image_region = pie.engine.CopyRegionParams{
        .w = 32 * 2,
        .h = 8 * 2,
    };
    const image_region_after = pie.engine.CopyRegionParams{
        .w = 32,
        .h = 8,
    };

    const size_bytes = image_region.w * image_region.h;
    var init_contents: [size_bytes]f16 = std.mem.zeroes([size_bytes]f16);

    init_contents[0] = @floatFromInt(1);
    init_contents[1] = @floatFromInt(2);
    init_contents[2] = @floatFromInt(3);
    init_contents[3] = @floatFromInt(4);
    init_contents[0 + image_region.w] = @floatFromInt(1);
    init_contents[1 + image_region.w] = @floatFromInt(2);
    init_contents[2 + image_region.w] = @floatFromInt(3);
    init_contents[3 + image_region.w] = @floatFromInt(4);

    std.log.info("\nUpload buffer contents:", .{});
    std.log.info("{any}...", .{init_contents[0..8]});
    std.log.info("{any}...", .{init_contents[image_region.w .. image_region.w + 8]});
    std.log.info("{any}...", .{init_contents[image_region.w * 2 .. image_region.w * 2 + 8]});
    std.log.info("{any}...", .{init_contents[image_region.w * 3 .. image_region.w * 3 + 8]});
    engine.mapUpload(&init_contents, image_region);

    engine.enqueueUpload(image_region) catch unreachable;
    engine.enqueueShader(shader_pipe, image_region_after);
    engine.enqueueDownload(image_region_after) catch unreachable;
    engine.run();

    const result = try engine.mapDownload(image_region_after);
    std.log.info("\nDownload buffer contents:", .{});
    std.log.info("{any}...", .{result[0..8]});
    std.log.info("{any}...", .{result[image_region_after.w .. image_region_after.w + 8]});
    std.log.info("{any}...", .{result[image_region_after.w * 2 .. image_region_after.w * 2 + 8]});
    std.log.info("{any}...", .{result[image_region_after.w * 3 .. image_region_after.w * 3 + 8]});

    const expected_contents = [_]f16{ 1, 2.5, 4, 1 };
    try std.testing.expect(std.mem.eql(f16, expected_contents[0..4], result[0..4]));
}
test "load raw, debayer, save" {
    // if (true) {
    //     return error.SkipZigTest;
    // }
    const allocator = std.testing.allocator;
    // Read contents from file
    const file_name = "testing/integration/DSC_6765.NEF";
    std.debug.print("Opening file: {s}\n", .{file_name});
    const file = try std.fs.cwd().openFile(file_name, .{});
    const file_info = try file.stat();
    std.debug.print("File size: {d} bytes\n", .{file_info.size});

    // create buffer and read entire file into it
    var buf: []u8 = try allocator.alloc(u8, file_info.size);
    defer allocator.free(buf);
    const read_size2 = try file.read(buf[0..]);
    std.debug.print("Read {d} bytes from file\n", .{read_size2});
    for (buf[0..4]) |b| {
        std.debug.print("{x} ", .{b});
    }
    std.debug.print("... \n", .{});

    const rp = libraw.libraw_init(0);

    const ret = libraw.libraw_open_buffer(rp, buf.ptr, buf.len);
    // const ret = libraw.libraw_open_file(rp, file_name);
    if (ret != libraw.LIBRAW_SUCCESS) {
        std.log.info("libraw_open failed: {d}", .{ret});
        try std.testing.expect(false);
        return;
    }
    std.log.info("libraw_open succeeded", .{});
    const ret2 = libraw.libraw_unpack(rp);
    if (ret2 != libraw.LIBRAW_SUCCESS) {
        std.log.info("libraw_unpack failed: {d}", .{ret2});
        try std.testing.expect(false);
        return;
    }
    std.log.info("libraw_unpack succeeded", .{});

    const ret3 = libraw.libraw_raw2image(rp);
    if (ret3 != libraw.LIBRAW_SUCCESS) {
        std.log.info("libraw_raw2image failed: {d}", .{ret3});
        try std.testing.expect(false);
        return;
    }
    std.log.info("libraw_raw2image succeeded", .{});

    const raw_image = rp.*.rawdata.raw_image;
    const image = rp.*.image;
    const img_width = rp.*.sizes.width;
    const img_height = rp.*.sizes.height;
    // try std.testing.expect(img_width == 6016);
    // try std.testing.expect(img_height == 4016);
    const pixel_count = @as(u32, img_width) * img_height;
    std.debug.print("Image raw size: {d}x{d}\n", .{ img_width, img_height });
    std.debug.print("Image raw isize: {d}x{d}\n", .{ rp.*.rawdata.sizes.iwidth, rp.*.rawdata.sizes.iheight });
    std.debug.print("Image raw size: {d}x{d}\n", .{ rp.*.rawdata.sizes.raw_width, rp.*.rawdata.sizes.raw_height });
    std.debug.print("Image raw pitch: {d}\n", .{rp.*.rawdata.sizes.raw_pitch});
    std.debug.print("Image pixels: {d}\n", .{pixel_count});
    std.debug.print("Image num vals: {d}\n", .{pixel_count * 4});
    std.debug.print("Image size flip: {d}\n", .{rp.*.sizes.flip});
    std.debug.print("Filters: {x}\n", .{rp.*.rawdata.iparams.filters});
    std.debug.print("Colors: {d}\n", .{rp.*.rawdata.iparams.colors});
    std.debug.print("Color Desc.: {s}\n", .{rp.*.rawdata.iparams.cdesc});

    // std.debug.print("Filters.: {x}\n", .{rp.*.idata.filters});
    // std.debug.print("Colors: {d}\n", .{rp.*.idata.colors});
    // std.debug.print("Color Desc.: {s}\n", .{rp.*.idata.cdesc});

    // std.log.info("Type of raw_image: (c_short = f32) {any}", .{@TypeOf(raw_image[0])});
    std.log.info("Type of image: (c_short = f32) {any}", .{@TypeOf(image[0][0])});

    // imgdata.color.maximum
    const max_value: f16 = @as(f16, @floatFromInt(rp.*.rawdata.color.maximum));
    std.log.info("Color Maximum: {d}", .{max_value});
    std.debug.print("\n\n", .{});

    std.debug.print("Raw Image first pixels\n", .{});
    for (raw_image[0..16]) |p| {
        std.debug.print("{d} ", .{p});
    }
    std.debug.print("\n\n", .{});

    std.debug.print("Image first pixels\n", .{});
    for (image[0..16]) |p| {
        std.debug.print("{d} {d} {d} {d}, ", .{ p[0], p[1], p[2], p[3] });
    }
    std.debug.print("\n\n", .{});

    std.log.info("Casting f16 to f32", .{});
    const init_contents_f32 = try allocator.alloc(f32, @as(u32, img_width * 2) * img_height * 2);
    defer allocator.free(init_contents_f32);

    // for (raw_image, 0..) |value, i| {
    //     init_contents_f32[i] = @as(f32, value);
    // }
    for (0..img_height) |y| {
        for (0..img_width) |x| {
            for (0..4) |ch| {
                const iindex = y * img_width + x;
                const oindex = (y * img_width + x) * 4 + ch;
                if (ch == 3) {
                    // alpha channel
                    init_contents_f32[oindex] = 1.0;
                    continue;
                }
                if (image[iindex][ch] == 0) {
                    init_contents_f32[oindex] = 0.0;
                    continue;
                } else {
                    init_contents_f32[oindex] += @as(f32, @floatFromInt(image[iindex][ch])) / @as(f32, max_value);
                    if (oindex < 16) {
                        std.debug.print("Pixel ({d}, {d}) channel {d}: raw {d}, image {d}, float {d}\n", .{
                            x,
                            y,
                            ch,
                            raw_image[iindex],
                            image[iindex][ch],
                            init_contents_f32[oindex],
                        });
                    }
                }
            }
        }
    }

    // EXPORT
    {
        const byte_array = std.mem.sliceAsBytes(init_contents_f32);
        std.log.info("Giving to zigimg", .{});
        var zigimage = try zigimg.Image.fromRawPixels(allocator, img_width, img_height, byte_array[0..], .float32);
        defer zigimage.deinit(allocator);
        // std.log.info("zigimg reads as: {any}", .{zigimage.pixels.float32[0..8]});
        try zigimage.convert(allocator, .rgba64);

        var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zigimage.writeToFilePath(allocator, "testing/integration/DSC_6765.png", write_buffer[0..], .{ .png = .{} });
    }

    if (true) {
        return error.SkipZigTest;
    }

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

    // convert from RGBG to RGGB
    var buf_rggb: []u16 = try allocator.alloc(u16, @as(u32, img_width) * img_height * 4);
    defer allocator.free(buf_rggb);
    for (0..img_height) |y| {
        for (0..img_width) |x| {
            // const index = y * img_width + x * 4;
            const index = y * img_width + x;
            buf_rggb[index] = raw_image[index];
            // buf_rggb[index + 1] = raw_image[index + 1];
            // buf_rggb[index + 2] = raw_image[index + 3];
            // buf_rggb[index + 3] = raw_image[index + 2];
        }
    }
    std.debug.print("First 16 pixels of rggb: \n", .{});
    for (buf_rggb[0..16]) |p| {
        std.debug.print("{d} ", .{p});
    }
    std.debug.print("... \n", .{});

    // DEBAYER WITH COMPUTE SHADER

    var engine = try pie.engine.Engine.init();
    defer engine.deinit();

    // https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/shader.wgsl
    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn debayer(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    var coords = vec2<i32>(global_id.xy);
        \\    let r = textureLoad(input, coords , 0).r;
        \\    let g1 = textureLoad(input, coords, 0).g;
        \\    let g2 = textureLoad(input, coords, 0).b;
        \\    let b = textureLoad(input, coords, 0).a;
        \\    let g = (g1 + g2) / 2.0;
        \\    let rgba = vec4f(r, g, b, 1.0);
        \\    //let rgba = vec4f(1.0, g, b, 1.0);
        \\    textureStore(output, coords, rgba);
        \\}
    ;
    var shader_pipe = try engine.compileShader(shader_code, "debayer");
    defer shader_pipe.deinit();

    const image_region = pie.engine.CopyRegionParams{
        .w = @as(u32, img_width),
        .h = @as(u32, img_height),
    };
    const image_region_after = pie.engine.CopyRegionParams{
        .w = @as(u32, img_width) / 2,
        .h = @as(u32, img_height) / 2,
    };
    // const image_region_after = pie.engine.CopyRegionParams{
    //     .w = @as(u32, img_width),
    //     .h = @as(u32, img_height),
    // };
    std.log.info("Image region: {any}", .{image_region});
    std.log.info("Image region after: {any}", .{image_region_after});

    var init_contents: []f16 = try allocator.alloc(f16, buf_rggb.len);
    defer allocator.free(init_contents);

    std.log.info("Normalizing u16 to f16", .{});
    for (buf_rggb, 0..) |val, i| {
        init_contents[i] = @as(f16, @floatFromInt(val)) / max_value;
    }

    std.log.info("\nUpload buffer contents: ", .{});
    std.debug.print("{any}...\n", .{init_contents[0..8]});
    std.debug.print("{any}...\n", .{init_contents[image_region.w .. image_region.w + 8]});
    std.debug.print("{any}...\n", .{init_contents[image_region.w * 2 .. image_region.w * 2 + 8]});
    std.debug.print("{any}...\n", .{init_contents[image_region.w * 3 .. image_region.w * 3 + 8]});
    std.debug.print("...\n", .{});
    std.debug.print("{any}...\n", .{init_contents[image_region.w * (image_region.h - 1) .. image_region.w * (image_region.h - 1) + 8]});

    std.log.info("Result length (pixels): {d}", .{buf_rggb.len});

    engine.mapUpload(init_contents, image_region);

    engine.enqueueUpload(image_region) catch unreachable;
    engine.enqueueShader(shader_pipe, image_region_after);
    engine.enqueueDownload(image_region_after) catch unreachable;
    engine.run();

    const result = try engine.mapDownload(image_region_after);
    std.log.info("\nDownload buffer contents: ", .{});
    std.debug.print("{any}...\n", .{result[0..8]});
    std.debug.print("{any}...\n", .{result[image_region_after.w .. image_region_after.w + 8]});
    std.debug.print("{any}...\n", .{result[image_region_after.w * 2 .. image_region_after.w * 2 + 8]});
    std.debug.print("{any}...\n", .{result[image_region_after.w * 3 .. image_region_after.w * 3 + 8]});
    std.debug.print("...\n", .{});
    std.debug.print("{any}...\n", .{result[image_region_after.w * (image_region_after.h - 1) .. image_region_after.w * (image_region_after.h - 1) + 8]});

    // std.log.info("\n{any}...", .{result[0..image_region_after.w]});
    // const expected_contents = [_]f16{ 1, 2.5, 4, 1 };
    // try std.testing.expect(std.mem.eql(f16, expected_contents[0..4], result[0..4]));

    // Calculate the size in bytes
    std.log.info("Result length (pixels): {d}", .{result.len});
    // std.log.info("Type of my_int: {any}", .{@TypeOf(result[0])});

    // EXPORT
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
        var zigimage2 = try zigimg.Image.fromRawPixels(allocator, image_region_after.w, image_region_after.h, byte_array2[0..], .float32);
        defer zigimage2.deinit(allocator);

        // std.log.info("zigimg reads as: {any}", .{zigimage2.pixels.float32[0..8]});
        try zigimage2.convert(allocator, .rgba64);
        var write_buffer2: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        try zigimage2.writeToFilePath(allocator, "testing/integration/DSC_6765_debayered.png", write_buffer2[0..], .{ .png = .{} });
        // try zigimage2.writeToFilePath(allocator, "testing/integration/DSC_6765_debayered.bmp", write_buffer2[0..], .{ .bmp = .{} });
        // try zigimage2.writeToFilePath(allocator, "testing/integration/DSC_6765_debayered.tiff", write_buffer2[0..], .{ .tiff = {} });
    }
}
