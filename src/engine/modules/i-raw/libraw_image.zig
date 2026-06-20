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
    white_balance: [4]f32,
    cam_to_srgb: [3][3]f32,
    // cam_to_xyz: [3][3]f32,
    filters: api.CFA,
    libraw_rp: *libraw.libraw_data_t,

    pub fn read(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !RawImage {
        const buf = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, allocator, .unlimited);
        defer allocator.free(buf);

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
        const black_base: u32 = libraw_rp.*.rawdata.color.black;
        const black_corr: [4]u32 = libraw_rp.*.rawdata.color.cblack[0..4].*; // first 4 entries are per-channel corrections
        const wb_coeff: [4]f32 = libraw_rp.*.rawdata.color.cam_mul; // camera (as shot) white balance
        // const wb_coeff: [4]f32 = libraw_rp.*.rawdata.color.pre_mul; // idk what this is, some sources say this is wb?
        // const white2: [8][8]u16 = libraw_rp.*.rawdata.color.white; //  daylight white balance (calculated from Adobe camera matrix)
        const white_signed: [4]i64 = libraw_rp.*.rawdata.color.linear_max; // per-channel linear maxima from metadata, black not subtracted
        const maximum: u32 = libraw_rp.*.rawdata.color.maximum; // format/camera maximum, may be adjusted by LibRaw in some paths
        const data_maximum: u32 = libraw_rp.*.rawdata.color.data_maximum; // measured maximum, populated in later processing paths for some formats
        const flip = libraw_rp.*.rawdata.sizes.flip;
        const user_flip = libraw_rp.*.params.user_flip;

        var black: [4]u32 = undefined;
        for (black_corr, 0..) |corr, i| {
            black[i] = black_base + corr;
        }

        var white: [4]u32 = undefined;
        for (white_signed[0..4], 0..) |val, i| {
            if (val > 0) {
                white[i] = @as(u32, @intCast(val));
            } else if (maximum > 0) {
                white[i] = maximum;
            } else if (data_maximum > 0) {
                white[i] = data_maximum;
            } else {
                white[i] = @as(u32, @intCast(libraw.libraw_get_color_maximum(libraw_rp)));
            }
        }

        const rgb_to_cam_all = libraw_rp.*.rawdata.color.rgb_cam;
        // drop last col
        var srgb_to_cam: [3][3]f32 = undefined;
        for (rgb_to_cam_all[0..3], 0..) |row, i| {
            for (row[0..3], 0..) |val, j| {
                srgb_to_cam[i][j] = val;
            }
        }
        // invert
        const cam_to_srgb = api.math.mat3.inv(f32, srgb_to_cam);

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
            .orientation = flip,
            .user_flip = user_flip,
            .black = black,
            .white = white,
            .white_balance = wb_coeff,
            .cam_to_srgb = cam_to_srgb,
            // .cam_to_xyz = cam_to_xyz,
            .filters = try api.CFA.fromLibraw(libraw_rp.*.rawdata.iparams.cdesc[0..], libraw_rp.*.rawdata.iparams.filters),
            .libraw_rp = libraw_rp,
        };
    }

    pub fn print(
        self: *RawImage,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("RawImage: {d}x{d}, orientation={d}, user_flip={d}\n", .{
            self.width,
            self.height,
            self.orientation,
            self.user_flip,
        });
        try writer.print("black: {d}, {d}, {d}, {d}\n", .{
            self.black[0],
            self.black[1],
            self.black[2],
            self.black[3],
        });
        try writer.print("white: {d}, {d}, {d}, {d}\n", .{
            self.white[0],
            self.white[1],
            self.white[2],
            self.white[3],
        });
        try writer.print("white_balance: {d}, {d}, {d}, {d}\n", .{
            self.white_balance[0],
            self.white_balance[1],
            self.white_balance[2],
            self.white_balance[3],
        });
        try writer.print("cam_to_srgb:\n{d} {d} {d}\n{d} {d} {d}\n{d} {d} {d}\n", .{
            self.cam_to_srgb[0][0], self.cam_to_srgb[0][1], self.cam_to_srgb[0][2],
            self.cam_to_srgb[1][0], self.cam_to_srgb[1][1], self.cam_to_srgb[1][2],
            self.cam_to_srgb[2][0], self.cam_to_srgb[2][1], self.cam_to_srgb[2][2],
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
