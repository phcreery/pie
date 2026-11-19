//! A connector is the data that flows between modules or nodes, plus the
//! color profile it carries. A connector holds one resource: a texture or a
//! storage buffer. The pipeline owns the resource and `deinit` frees it.

const gpu = @import("gpu");
const ColorProfile = @import("module_types").ColorProfile;

/// The allocated resource. A null slot is a lazy connector that the pipeline
/// fills during allocation.
texture: ?gpu.Texture = null,
buffer: ?gpu.Buffer = null,
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
    if (self.texture) |*t| t.deinit();
    self.texture = null;
    if (self.buffer) |*b| b.deinit();
    self.buffer = null;
}

/// True when no resource is allocated.
pub fn isEmpty(self: *const Self) bool {
    return self.texture == null and self.buffer == null;
}
