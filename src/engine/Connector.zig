/// A connector is the image data flowing between modules/nodes plus the color
/// profile it carries. The pipeline owns the texture; `deinit` frees it.
const gpu = @import("gpu/root.zig");
const ROI = @import("ROI.zig");
const api = @import("modules/api.zig");

/// White point of the working/connection color space.
pub const WhitePoint = enum(i32) {
    any = -1, // module does not care about the white point
    d65 = 0,
    d50 = 1,
};

/// Primaries (gamut) of the working/connection color space.
pub const Primaries = enum(i32) {
    any = -1, // module does not care about the primaries
    camera = 0,
    rec709 = 1,
    rec2020 = 2,
};

/// Describes the color profile a socket accepts/emits or that a connector
/// carries between modules/nodes.
pub const ColorProfile = struct {
    white_point: WhitePoint,
    primaries: Primaries,

    pub const any = ColorProfile{ .white_point = .any, .primaries = .any };

    /// Whether `self` (an emitted profile) is accepted by `accepted` (a
    /// socket's declared accept-profile). An `.any` field on either side
    /// matches anything.
    pub fn acceptedBy(self: ColorProfile, accepted: ColorProfile) bool {
        return profileFieldCompatible(self.white_point, accepted.white_point) and
            profileFieldCompatible(self.primaries, accepted.primaries);
    }

    fn profileFieldCompatible(emitted: anytype, accepted: anytype) bool {
        return emitted == .any or accepted == .any or emitted == accepted;
    }
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
