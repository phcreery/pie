//! Low-level resource vocabulary shared by the GPU layer and the module API.

pub const ROI = @import("ROI.zig");
pub const std140 = @import("std140.zig");

/// Where the samples live: a texture channel layout, a storage buffer, or a
/// wildcard resolved from the connection.
///
/// `.rggb` is a *semantic* single-channel texture: the data is RGGB bayer
/// mosaic, but it is stored one photosite per texel on the GPU. Shaders decode
/// the bayer phase from coords; WGSL declares the underlying storage type.
pub const Resource = enum {
    r,
    rgba,
    rggb,
    buffer,
    any,

    /// Number of channels stored per element.
    pub fn channels(self: Resource) u32 {
        return switch (self) {
            .rgba => 4,
            .r, .rggb, .buffer => 1,
            .any => 1,
        };
    }
};

/// The scalar element type. For textures this is the channel type. For
/// buffers this is the type of one array element.
pub const DataType = enum {
    u8,
    u16,
    u32,
    i32,
    f16,
    f32,
    any,

    /// Bytes per scalar element.
    pub fn elementSize(self: DataType) u32 {
        return switch (self) {
            .u8 => 1,
            .u16, .f16 => 2,
            .u32, .i32, .f32 => 4,
            .any => 1,
        };
    }
};

test {
    _ = ROI;
    _ = Resource;
    _ = DataType;
    _ = std140;
}
