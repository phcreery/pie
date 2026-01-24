const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const CFA = @import("modules/shared/CFA.zig");
const slog = std.log.scoped(.imgparam);

// see: https://github.com/hanatos/vkdt/blob/master/src/pipe/module.h#L52

pub const ImgParams = struct {
    temp: f32 = 1.0,
    // black: [4]f32, // black point
    // white: [4]f32, // clipping threshold
    // whitebalance: [4]f32, // camera white balance coefficients
    // cfa: CFA, // color filter array multipliers

    // cam_to_rec2020: [3][3]f32, // color space conversion matrix
};

// https://webgpufundamentals.org/webgpu/lessons/webgpu-memory-layout.html
// TODO: move to gpu.zig

pub fn size(t: type) usize {
    switch (t) {
        f32 => return @sizeOf(f32),
        else => return 0,
    }
}

pub fn alignment(t: type) usize {
    switch (t) {
        f32 => return 4,
        else => return 1,
    }
}

// pub fn toBytes(self: *const ImgParams) []u8 {
//     return std.mem.asBytes(@constCast(self));
// }
