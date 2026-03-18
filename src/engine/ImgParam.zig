const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const CFA = @import("modules/shared/CFA.zig");
const slog = std.log.scoped(.imgparam);

// see: https://github.com/hanatos/vkdt/blob/master/src/pipe/module.h#L52

pub const Orientation = enum(i32) {
    normal = 1,
    rotate180 = 3,
    rotate90CW = 6,
    rotate270CW = 8,
};

pub const ImgParams = struct {
    black: [4]f32, // black point
    white: [4]f32, // clipping threshold
    white_balance: [4]f32, // camera white balance coefficients
    // orientation from image metadata (EXIF-style): 1 = normal, 3 = 180, 6 = 90 CW, 8 = 270 CW
    orientation: Orientation,
    // cfa: CFA, // color filter array multipliers
    // cam_to_rec2020: [3][3]f32, // color space conversion matrix
    cam_to_srgb: [3][3]f32, // color space conversion matrix

    pub fn print(
        self: *ImgParams,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("ImgParams: orientation={d}\n", .{self.orientation});
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
};
