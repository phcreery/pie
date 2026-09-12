//! GPU module root: shared constants, helpers, and re-exports of the per-type
//! files that make up the GPU abstraction layer.
//!
//! A lot of this is just a wrapper around wgpu to make it easier to use in the context of image processing.
//! intended to be used with [shahwali/wgpu-zig](https://codeberg.org/shahwali/wgpu-zig) (wgpu-native)

const std = @import("std");
pub const data = @import("data.zig");

// ================
// CONSTANTS
// ================

pub const MAX_BIND_GROUPS: usize = 4;
pub const MAX_BINDINGS: usize = 8;

// Workgroup size must match the compute shader
pub const WORKGROUP_SIZE_X: u32 = 8;
pub const WORKGROUP_SIZE_Y: u32 = 8;
pub const WORKGROUP_SIZE_Z: u32 = 1;

// Copy error Buffer offset 4 is not aligned to block size or `COPY_BUFFER_ALIGNMENT`
// https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
pub const COPY_BUFFER_ALIGNMENT: std.mem.Alignment = .@"8";
pub const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256; // wgpu.COPY_BYTES_PER_ROW_ALIGNMENT

/// Round `bytes_per_row` up to a multiple of `COPY_BYTES_PER_ROW_ALIGNMENT`.
pub fn alignBytesPerRow(bytes_per_row: u32) u32 {
    return ((bytes_per_row + COPY_BYTES_PER_ROW_ALIGNMENT - 1) / COPY_BYTES_PER_ROW_ALIGNMENT) * COPY_BYTES_PER_ROW_ALIGNMENT;
}

// ================
// TYPES
// ================

pub const Buffer = @import("Buffer.zig");
pub const MemoryType = Buffer.MemoryType;
pub const Encoder = @import("Encoder.zig");
pub const Texture = @import("Texture.zig");
pub const TextureFormat = Texture.TextureFormat;
pub const Bindings = @import("Bindings.zig");
pub const BindGroupEntry = Bindings.BindGroupEntry;
pub const Shader = @import("Shader.zig");
pub const ShaderLanguage = Shader.ShaderLanguage;
pub const ShaderSource = Shader.ShaderSource;
pub const ShaderSourceContext = Shader.ShaderSourceContext;
pub const ShaderMap = Shader.ShaderMap;
pub const ComputePipeline = @import("ComputePipeline.zig");
pub const BindGroupLayoutEntry = ComputePipeline.BindGroupLayoutEntry;
pub const BindGroupLayoutEntryAccess = BindGroupLayoutEntry.BindGroupLayoutEntryAccess;
pub const BindGroupLayoutTextureEntry = BindGroupLayoutEntry.BindGroupLayoutTextureEntry;
pub const BindGroupLayoutBufferEntryType = BindGroupLayoutEntry.BindGroupLayoutBufferEntryType;
pub const BindGroupLayoutBufferEntry = BindGroupLayoutEntry.BindGroupLayoutBufferEntry;
pub const GPU = @import("GPU.zig");
