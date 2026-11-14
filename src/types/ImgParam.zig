const std = @import("std");
// const CFA = @import("modules/shared/CFA.zig");
const slog = std.log.scoped(.imgparam);
const std140 = @import("std140.zig");
const math = @import("math");

// see: https://github.com/hanatos/vkdt/blob/master/src/pipe/module.h#L52

pub const Orientation = enum(i32) {
    normal = 1,
    rotate180 = 3,
    rotate90CW = 6,
    rotate270CW = 8,
};

pub const ImgParams = struct {
    // the color profile is the gamut and white point of the image for any given step in the pipeline

    black: math.Vec4, // black point
    white: math.Vec4, // clipping threshold

    // camera white balance coefficients
    white_balance: math.Vec4,

    // orientation from image metadata (EXIF-style): 1 = normal, 3 = 180, 6 = 90 CW, 8 = 270 CW
    orientation: Orientation,

    // color filter array multipliers
    // cfa: CFA,

    rec2020_from_cam: math.Mat3.asVectors,

    // XYZ <- camera color space conversion matrix. XYZ is in D65 white point, linear. Similar to Adobe DNG ColorMatrix2, but with the two green channels collapsed into one.
    xyz_d65_from_cam: math.Mat3.asVectors,

    pub fn print(
        self: *ImgParams,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("ImgParams:\n", .{});
        try writer.print("orientation={d}\n", .{self.orientation});
        try writer.print("black: {d}, {d}, {d}, {d}\n", .{
            self.black.x,
            self.black.y,
            self.black.z,
            self.black.w,
        });
        try writer.print("white: {d}, {d}, {d}, {d}\n", .{
            self.white.x,
            self.white.y,
            self.white.z,
            self.white.w,
        });
        try writer.print("white_balance: {d}, {d}, {d}, {d}\n", .{
            self.white_balance.x,
            self.white_balance.y,
            self.white_balance.z,
            self.white_balance.w,
        });
        // try writer.print("srgb_from_cam:\n{d} {d} {d}\n{d} {d} {d}\n{d} {d} {d}\n", .{
        //     self.srgb_from_cam[0][0], self.srgb_from_cam[0][1], self.srgb_from_cam[0][2],
        //     self.srgb_from_cam[1][0], self.srgb_from_cam[1][1], self.srgb_from_cam[1][2],
        //     self.srgb_from_cam[2][0], self.srgb_from_cam[2][1], self.srgb_from_cam[2][2],
        // });
        try writer.print("rec2020_from_cam:\n{d} {d} {d}\n{d} {d} {d}\n{d} {d} {d}\n", .{
            self.rec2020_from_cam[0][0], self.rec2020_from_cam[0][1], self.rec2020_from_cam[0][2],
            self.rec2020_from_cam[1][0], self.rec2020_from_cam[1][1], self.rec2020_from_cam[1][2],
            self.rec2020_from_cam[2][0], self.rec2020_from_cam[2][1], self.rec2020_from_cam[2][2],
        });
        try writer.print("xyz_d65_from_cam:\n{d} {d} {d}\n{d} {d} {d}\n{d} {d} {d}\n", .{
            self.xyz_d65_from_cam[0][0], self.xyz_d65_from_cam[0][1], self.xyz_d65_from_cam[0][2],
            self.xyz_d65_from_cam[1][0], self.xyz_d65_from_cam[1][1], self.xyz_d65_from_cam[1][2],
            self.xyz_d65_from_cam[2][0], self.xyz_d65_from_cam[2][1], self.xyz_d65_from_cam[2][2],
        });
    }
};

/// The `img_params` uniform buffer as the shaders see it: `ImgParams` packed by
/// `types.std140.layoutStruct` and respelled as an extern struct by `std140`.
pub const ImgParamsGpu = std140.GpuStruct(ImgParams);

test "layoutStruct packs ImgParams as its std140 GPU view" {
    const rec2020 = math.Mat3.fromArray(.{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } });
    const xyz = math.Mat3.fromArray(.{ .{ 9, 8, 7 }, .{ 6, 5, 4 }, .{ 3, 2, 1 } });
    const params: ImgParams = .{
        .black = math.Vec4.new(0.1, 0.2, 0.3, 0.4),
        .white = math.Vec4.new(1.1, 1.2, 1.3, 1.4),
        .white_balance = math.Vec4.new(2.1, 2.2, 2.3, 2.4),
        .orientation = .rotate90CW,
        .rec2020_from_cam = rec2020.toVectors(),
        .xyz_d65_from_cam = xyz.toVectors(),
    };

    // The GPU matrix type is `[3]@Vector(3, f32)`, which native code cannot
    // place in an extern struct. `Columns` has the same bytes.
    const Expected = extern struct {
        black: math.Vec4 align(16),
        white: math.Vec4 align(16),
        white_balance: math.Vec4 align(16),
        orientation: Orientation,
        rec2020_from_cam: math.Mat3.Columns align(16),
        xyz_d65_from_cam: math.Mat3.Columns align(16),
    };

    var buf: [@sizeOf(Expected)]u8 = @splat(0);
    try std.testing.expectEqual(@sizeOf(Expected), try std140.layoutStruct(&buf, params));

    // Zeroed so the struct's padding (vec4 `w`, 16-byte matrix padding) matches
    // the untouched padding bytes the packer leaves behind.
    var expected: Expected = undefined;
    @memset(std.mem.asBytes(&expected), 0);
    expected.black = params.black;
    expected.white = params.white;
    expected.white_balance = params.white_balance;
    expected.orientation = params.orientation;
    expected.rec2020_from_cam = rec2020.toStruct();
    expected.xyz_d65_from_cam = xyz.toStruct();

    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), &buf);
}
