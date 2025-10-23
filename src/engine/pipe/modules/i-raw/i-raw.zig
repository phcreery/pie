const std = @import("std");
const libraw = @import("libraw");
const bayer_filters = @import("../shared/bayer_filters.zig");

pub const RawImage = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    raw_image: []f16,
    max_value: f16,
    filters: bayer_filters.BayerFilters,
    libraw_rp: *libraw.libraw_data_t,

    pub fn read(allocator: std.mem.Allocator, file: std.fs.File) !RawImage {
        const file_info = try file.stat();
        // create buffer and read entire file into it
        var buf: []u8 = try allocator.alloc(u8, file_info.size);
        defer allocator.free(buf);
        _ = try file.read(buf[0..]);

        const libraw_rp = libraw.libraw_init(0);

        const ret = libraw.libraw_open_buffer(libraw_rp, buf.ptr, buf.len);
        if (ret != libraw.LIBRAW_SUCCESS) {
            return error.OpenFailed;
        }
        std.log.info("libraw_open succeeded", .{});
        const ret2 = libraw.libraw_unpack(libraw_rp);
        if (ret2 != libraw.LIBRAW_SUCCESS) {
            return error.UnpackFailed;
        }
        std.log.info("libraw_unpack succeeded", .{});
        // TODO: some of the stuff libraw.libraw_raw2image(libraw_rp); does

        const img_width: u16 = libraw_rp.*.sizes.width;
        const img_height: u16 = libraw_rp.*.sizes.height;
        const raw_image: [*c]const u16 = libraw_rp.*.rawdata.raw_image;
        const raw_pixel_count = @as(u32, img_width) * img_height;
        const max_value: u32 = libraw_rp.*.rawdata.color.maximum;

        std.log.info("Filters: {x} ({b})", .{ libraw_rp.*.rawdata.iparams.filters, libraw_rp.*.rawdata.iparams.filters });
        std.log.info("Color Desc.: {s}", .{libraw_rp.*.rawdata.iparams.cdesc});
        // std.log.info("Type of raw_image: (c_short = i16, c_ushort = u16) {any}", .{@TypeOf(raw_image[0])});

        std.log.info("Casting u16 to f16 and Normalizing", .{});
        var raw_image_norm: []f16 = try allocator.alloc(f16, raw_pixel_count);
        errdefer allocator.free(raw_image_norm);
        for (raw_image, 0..raw_pixel_count) |value, i| {
            if (raw_image_norm[i] == 0.0) {
                raw_image_norm[i] = 0.0;
                continue;
            }
            raw_image_norm[i] = @as(f16, @floatFromInt(value)) / @as(f16, @floatFromInt(max_value));
            if (i < 16) {
                std.debug.print("raw {d}, float {d}\n", .{
                    raw_image[i],
                    raw_image_norm[i],
                });
            }
        }

        return RawImage{
            .allocator = allocator,
            .width = img_width,
            .height = img_height,
            .raw_image = raw_image_norm,
            .max_value = @as(f16, @floatFromInt(max_value)),
            .filters = try bayer_filters.BayerFilters.from_libraw(libraw_rp.*.rawdata.iparams.filters),
            .libraw_rp = libraw_rp,
        };
    }

    pub fn deinit(self: *RawImage) void {
        self.allocator.free(self.raw_image);

        libraw.libraw_recycle(self.libraw_rp);
        libraw.libraw_close(self.libraw_rp);
    }
};

test "open raw image" {
    const allocator = std.testing.allocator;
    const file = try std.fs.cwd().openFile("testing/integration/DSC_6765.NEF", .{});
    var raw_image = try RawImage.read(allocator, file);
    defer raw_image.deinit();
    try std.testing.expect(raw_image.width == 6016);
    try std.testing.expect(raw_image.height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_width == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iwidth == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iheight == 4016);
    try std.testing.expectEqual([2][2]bayer_filters.FilterColor{
        .{ .R, .G },
        .{ .G2, .B },
    }, raw_image.filters.pattern);
}
