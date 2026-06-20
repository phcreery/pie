const api = @import("../api.zig");
const libraw = @import("libraw");
const std = @import("std");

pub const RawImage = struct {
    width: usize,
    height: usize,
    raw_image: []u16,
    orientation: i32,
    user_flip: i32,
    black: [4]u32,
    white: [4]u32,
    cam_mul: [4]f32,
    pre_mul: [4]f32,
    rgb_cam: [3][4]f32,
    cam_xyz: [3][3]f32,
    filters: api.CFA,
    libraw_rp: *libraw.libraw_data_t,

    pub fn read(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !RawImage {
        const buf = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, allocator, .unlimited);
        defer allocator.free(buf);

        const libraw_rp = libraw.libraw_init(0);

        const ret = libraw.libraw_open_buffer(libraw_rp, buf.ptr, buf.len);
        if (ret != libraw.LIBRAW_SUCCESS) return error.OpenFailed;
        const ret2 = libraw.libraw_unpack(libraw_rp);
        if (ret2 != libraw.LIBRAW_SUCCESS) return error.UnpackFailed;

        const img_width: u16 = libraw_rp.*.sizes.width;
        const img_height: u16 = libraw_rp.*.sizes.height;
        const raw_image: []u16 = std.mem.span(libraw_rp.*.rawdata.raw_image);
        const black_base: u32 = libraw_rp.*.rawdata.color.black;
        const black_corr: [4]u32 = libraw_rp.*.rawdata.color.cblack[0..4].*;
        const cam_mul: [4]f32 = libraw_rp.*.rawdata.color.cam_mul;
        const pre_mul: [4]f32 = libraw_rp.*.rawdata.color.pre_mul;
        const white_signed: [4]c_long = libraw_rp.*.rawdata.color.linear_max;
        const maximum: u32 = libraw_rp.*.rawdata.color.maximum;
        const data_maximum: u32 = libraw_rp.*.rawdata.color.data_maximum;
        const flip = libraw_rp.*.rawdata.sizes.flip;
        const user_flip = libraw_rp.*.params.user_flip;

        var black: [4]u32 = undefined;
        for (black_corr, 0..) |corr, i| black[i] = black_base + corr;

        var white: [4]u32 = undefined;
        for (white_signed[0..4], 0..) |val_c, i| {
            const val = @as(u32, @intCast(val_c));
            if (val > 0) {
                white[i] = val;
            } else if (maximum > 0) {
                white[i] = maximum;
            } else if (data_maximum > 0) {
                white[i] = data_maximum;
            } else {
                white[i] = @as(u32, @intCast(libraw.libraw_get_color_maximum(libraw_rp)));
            }
        }

        const rgb_cam = libraw_rp.*.rawdata.color.rgb_cam;

        const cam_xyz_all: [4][3]f32 = libraw_rp.*.rawdata.color.cam_xyz;
        var cam_xyz: [3][3]f32 = undefined;
        for (cam_xyz_all[0..3], 0..) |row, i| cam_xyz[i] = row;

        return .{
            .width = img_width,
            .height = img_height,
            .raw_image = raw_image,
            .orientation = flip,
            .user_flip = user_flip,
            .black = black,
            .white = white,
            .cam_mul = cam_mul,
            .pre_mul = pre_mul,
            .rgb_cam = rgb_cam,
            .cam_xyz = cam_xyz,
            .filters = try api.CFA.fromLibraw(libraw_rp.*.rawdata.iparams.cdesc[0..], libraw_rp.*.rawdata.iparams.filters),
            .libraw_rp = libraw_rp,
        };
    }

    pub fn print(self: *RawImage, writer: *std.Io.Writer) !void {
        try writer.print("RawImage: {d}x{d}, orientation={d}, user_flip={d}\n", .{ self.width, self.height, self.orientation, self.user_flip });
        try writer.print("black: {d}, {d}, {d}, {d}\n", .{ self.black[0], self.black[1], self.black[2], self.black[3] });
        try writer.print("white: {d}, {d}, {d}, {d}\n", .{ self.white[0], self.white[1], self.white[2], self.white[3] });
        try writer.print("cam_mul: {d}, {d}, {d}, {d}\n", .{ self.cam_mul[0], self.cam_mul[1], self.cam_mul[2], self.cam_mul[3] });
        try writer.print("pre_mul: {d}, {d}, {d}, {d}\n", .{ self.pre_mul[0], self.pre_mul[1], self.pre_mul[2], self.pre_mul[3] });
        try writer.print("rgb_cam:\n{d} {d} {d} {d}\n{d} {d} {d} {d}\n{d} {d} {d} {d}\n", .{
            self.rgb_cam[0][0], self.rgb_cam[0][1], self.rgb_cam[0][2], self.rgb_cam[0][3],
            self.rgb_cam[1][0], self.rgb_cam[1][1], self.rgb_cam[1][2], self.rgb_cam[1][3],
            self.rgb_cam[2][0], self.rgb_cam[2][1], self.rgb_cam[2][2], self.rgb_cam[2][3],
        });
        try writer.print("cam_xyz:\n{d} {d} {d}\n{d} {d} {d}\n{d} {d} {d}\n", .{
            self.cam_xyz[0][0], self.cam_xyz[0][1], self.cam_xyz[0][2],
            self.cam_xyz[1][0], self.cam_xyz[1][1], self.cam_xyz[1][2],
            self.cam_xyz[2][0], self.cam_xyz[2][1], self.cam_xyz[2][2],
        });
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
    const io = std.testing.io;
    var raw_image = try RawImage.read(allocator, io, "testing/images/DSC_6765.NEF");
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
