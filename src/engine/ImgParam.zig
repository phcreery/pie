const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const CFA = @import("modules/shared/CFA.zig");
const slog = std.log.scoped(.imgparam);

// see: https://github.com/hanatos/vkdt/blob/master/src/pipe/module.h#L52

pub const ImgParams = struct {
    // float: f32 = 1.0,
    // vec3: [3]f32 = .{ 1.0, 2.0, 3.0 },
    // mat3x3: [3][3]f32 = .{
    //     .{ 1.0, 0.0, 0.0 },
    //     .{ 0.0, 2.0, 0.0 },
    //     .{ 0.0, 0.0, 3.0 },
    // },

    black: [4]f32, // black point
    white: [4]f32, // clipping threshold
    white_balance: [4]f32, // camera white balance coefficients
    // cfa: CFA, // color filter array multipliers
    cam_to_rec2020: [3][3]f32, // color space conversion matrix

    // cam_to_rec2020: [3][3]f32, // color space conversion matrix
};
