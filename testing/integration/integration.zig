const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");

pub fn main() !void {
    std.log.info("Starting Integration tests", .{});
}

// comptime {
//     _ = @import("engine.zig");
// }

test "libraw open bayer" {
    const allocator = std.testing.allocator;
    // Read contents from file
    const file = try std.fs.cwd().openFile("testing/integration/DSC_6765.NEF", .{});
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
    std.debug.print("\n", .{});

    const rp = libraw.libraw_init(0);

    // const ret = libraw.libraw_open_buffer(rp, c_buf, c_read_size);
    const ret = libraw.libraw_open_file(rp, "testing/integration/DSC_6765.NEF");
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
    const raw_image = rp.*.rawdata.raw_image;
    // print first 16 pixels
    for (raw_image[0..16]) |p| {
        std.debug.print("{d} ", .{p});
    }
}
