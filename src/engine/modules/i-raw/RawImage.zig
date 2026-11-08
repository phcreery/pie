const std = @import("std");
const api = @import("../api.zig");

// https://exiftool.org/TagNames/EXIF.html#LightSource
pub const LigthSourceWBCoeffs = struct {
    a: [4]i32,
    d55: [4]i32,
    d65: [4]i32,
};

/// kept so `deinit` can lock the shared libraw mutex
io: std.Io,
width: usize,
height: usize,
raw_image: []u16,
orientation: i32,
user_flip: i32,
/// Minimum black level for each channel
black: [4]u32,
/// Maximum white level for each channel
white: [4]u32,
/// Camera white balance multipliers (as read from the raw file)
wb_coeffs: [4]f32,
/// White balance coefficients for daylight (daylight balance)
// pre_mul: [4]f32,
lightsource_wb_coeffs: LigthSourceWBCoeffs,
xyz_d65_from_cam: [3][3]f32,
filters: api.CFA,

// iso
// exposure
// aperture
// focal_length

data: *anyopaque,

const Self = @This();

pub fn print(self: *Self, writer: *std.Io.Writer) !void {
    try writer.print("RawImage: {d}x{d}, orientation={d}, user_flip={d}\n", .{ self.width, self.height, self.orientation, self.user_flip });
    try writer.print("black: {d}, {d}, {d}, {d}\n", .{ self.black[0], self.black[1], self.black[2], self.black[3] });
    try writer.print("white: {d}, {d}, {d}, {d}\n", .{ self.white[0], self.white[1], self.white[2], self.white[3] });
    try writer.print("wb_coeffs: {d}, {d}, {d}, {d}\n", .{ self.wb_coeffs[0], self.wb_coeffs[1], self.wb_coeffs[2], self.wb_coeffs[3] });
    // try writer.print("pre_mul: {d}, {d}, {d}, {d}\n", .{ self.pre_mul[0], self.pre_mul[1], self.pre_mul[2], self.pre_mul[3] });
    try writer.print("lightsource_wb_coeffs.a: {d}, {d}, {d}\n", .{ self.lightsource_wb_coeffs.a[0], self.lightsource_wb_coeffs.a[1], self.lightsource_wb_coeffs.a[2] });
    try writer.print("lightsource_wb_coeffs.d55: {d}, {d}, {d}\n", .{ self.lightsource_wb_coeffs.d55[0], self.lightsource_wb_coeffs.d55[1], self.lightsource_wb_coeffs.d55[2] });
    try writer.print("lightsource_wb_coeffs.d65: {d}, {d}, {d}\n", .{ self.lightsource_wb_coeffs.d65[0], self.lightsource_wb_coeffs.d65[1], self.lightsource_wb_coeffs.d65[2] });
}
