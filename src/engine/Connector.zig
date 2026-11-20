//! A connector is the data that flows between modules or nodes, plus the
//! color profile it carries. A connector holds one resource: a texture or a
//! storage buffer. The pipeline owns the resource and `deinit` frees it.

const gpu = @import("gpu");
const ColorProfile = @import("module_types").ColorProfile;

/// The allocated GPU resource. Exactly one variant is live; `null` in
/// `Connector.data` is a lazy connector that the pipeline fills during
/// allocation.
pub const Data = union(enum) {
    texture: gpu.Texture,
    buffer: gpu.Buffer,
};

/// The allocated resource, or null before allocation.
data: ?Data = null,
color_profile: ColorProfile,

const Self = @This();

/// A slot with no resource yet. The pipeline allocates it later. The color
/// profile is available before allocation.
pub fn initNull(color_profile: ColorProfile) Self {
    return .{
        .color_profile = color_profile,
    };
}

pub fn deinit(self: *Self) void {
    if (self.data) |*data| switch (data.*) {
        .texture => |*texture| texture.deinit(),
        .buffer => |*buffer| buffer.deinit(),
    };
    self.data = null;
}

/// True when no resource is allocated.
pub fn isEmpty(self: *const Self) bool {
    return self.data == null;
}
