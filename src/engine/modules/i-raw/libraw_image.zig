const api = @import("../api.zig");
const libraw = @import("libraw");
const std = @import("std");

pub const RawImage = struct {
    width: usize,
    height: usize,
    raw_image: []u16,
    cblack: [4]u32,
    white: u32,
    wb_coeff: [4]f32,
    cam_xyz: [3][3]f32,
    filters: api.CFA,
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
        const ret2 = libraw.libraw_unpack(libraw_rp);
        if (ret2 != libraw.LIBRAW_SUCCESS) {
            return error.UnpackFailed;
        }
        // TODO: some of the stuff libraw.libraw_raw2image(libraw_rp); does

        const img_width: u16 = libraw_rp.*.sizes.width;
        const img_height: u16 = libraw_rp.*.sizes.height;
        const raw_image: []u16 = std.mem.span(libraw_rp.*.rawdata.raw_image);
        const white: u32 = libraw_rp.*.rawdata.color.maximum;
        const cblack: [4]u32 = libraw_rp.*.rawdata.color.cblack[0..4].*; // TODO: xtans uses more than 4
        const wb_coeff: [4]f32 = libraw_rp.*.rawdata.color.cam_mul; // or pre_mul??
        const cam_xyz_all: [4][3]f32 = libraw_rp.*.rawdata.color.cam_xyz;
        // drop last row
        var cam_xyz: [3][3]f32 = undefined;
        for (cam_xyz_all[0..3], 0..) |row, i| {
            cam_xyz[i] = row;
        }

        return RawImage{
            .width = img_width,
            .height = img_height,
            .raw_image = raw_image,
            .cblack = cblack,
            .white = white,
            .wb_coeff = wb_coeff,
            .cam_xyz = cam_xyz,
            .filters = try api.CFA.fromLibraw(&libraw_rp.*.rawdata.iparams.cdesc, libraw_rp.*.rawdata.iparams.filters),
            .libraw_rp = libraw_rp,
        };
    }

    pub fn deinit(self: *RawImage) void {
        libraw.libraw_recycle(self.libraw_rp);
        libraw.libraw_close(self.libraw_rp);
    }
};

test "libraw version" {
    const version = libraw.libraw_version();
    std.log.info("LibRaw version: {s}", .{version});
    try std.testing.expect(version.len > 0);
}

test "open raw image" {
    const allocator = std.testing.allocator;
    const file = try std.fs.cwd().openFile("testing/images/DSC_6765.NEF", .{});
    var raw_image = try RawImage.read(allocator, file);
    defer raw_image.deinit();
    try std.testing.expect(raw_image.width == 6016);
    try std.testing.expect(raw_image.height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_width == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iwidth == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iheight == 4016);
    try std.testing.expectEqual([2][2]api.CFA.FilterColor{
        .{ .R, .G },
        .{ .G2, .B },
    }, raw_image.filters.pattern);
}
