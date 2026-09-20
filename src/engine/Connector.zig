//! A connector is the image data flowing between modules/nodes plus the color
//! profile it carries. The pipeline owns the texture; `deinit` frees it.

const std = @import("std");
const gpu = @import("gpu");
const ROI = @import("types").ROI;
const ColorProfile = @import("types").ColorProfile;

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
    return .{
        .texture = texture,
        .color_profile = color_profile,
    };
}

/// A slot with no texture yet (allocated lazily by the pipeline). Carries
/// the color profile so the metadata is available even before allocation.
pub fn initNull(color_profile: ColorProfile) Self {
    return .{
        .texture = null,
        .color_profile = color_profile,
    };
}

pub fn deinit(self: *Self) void {
    if (self.texture) |*t| t.deinit();
    self.texture = null;
}
