const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const api = @import("modules/api.zig");

pub const WhitePoint = enum(i32) {
    d65 = 0,
    d50 = 1,
};

pub const Primaries = enum(i32) {
    camera = 0,
    rec709 = 1,
    rec2020 = 2,
};

pub const ColorProfile = struct {
    white_point: WhitePoint,
    primaries: Primaries,
};

texture: ?gpu.Texture,
color_profile: ColorProfile,

const Self = @This();

pub fn init(
    gpu_inst: *gpu.GPU,
    name: []const u8,
    color_profile: ColorProfile,
    format: gpu.TextureFormat,
    roi: ROI,
) !Self {
    const texture = try gpu.Texture.init(gpu_inst, name, format, roi);
    return Self{
        .texture = texture,
        .color_profile = color_profile,
    };
}
