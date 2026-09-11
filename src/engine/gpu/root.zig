//! GPU module root: shared constants, helpers, and re-exports of the per-type
//! files that make up the GPU abstraction layer.
//!
//! A lot of this is just a wrapper around wgpu to make it easier to use in the context of image processing.
//! intended to be used with [shahwali/wgpu-zig](https://codeberg.org/shahwali/wgpu-zig) (wgpu-native)

const std = @import("std");
const gpu_data = @import("data.zig");

// ================
// CONSTANTS
// ================

pub const MAX_BIND_GROUPS: usize = 4;
pub const MAX_BINDINGS: usize = 8;

// Workgroup size must match the compute shader
pub const WORKGROUP_SIZE_X: u32 = 8;
pub const WORKGROUP_SIZE_Y: u32 = 8;
pub const WORKGROUP_SIZE_Z: u32 = 1;

pub const layoutStruct = gpu_data.layoutStruct;

// Copy error Buffer offset 4 is not aligned to block size or `COPY_BUFFER_ALIGNMENT`
// https://github.com/gfx-rs/wgpu/blob/trunk/wgpu-types/src/lib.rs#L96
pub const COPY_BUFFER_ALIGNMENT: std.mem.Alignment = .@"8";
pub const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256; // wgpu.COPY_BYTES_PER_ROW_ALIGNMENT

// ================
// HELPERS
// ================

/// Copy a dense (row-contiguous) pixel buffer into a GPU staging region that
/// uses wgpu's required padded row stride (bytesPerRow multiple of 256).
/// `dst` is the mapped staging pointer (already sized by the caller for the
/// padded layout); `src` is the dense source slice; `width`/`height` are the
/// texel dimensions and `bpp` the bytes per texel of the source.
///
/// This is the inverse of reading `enqueueTexToBuf` output, and is what source
/// modules should use in `readSource` when the raw buffer is row-contiguous.
pub fn copyDenseToStaging(dst: *anyopaque, src: []const u8, width: u32, height: u32, bpp: u32) void {
    const bytes_per_row = width * bpp;
    const padded_bytes_per_row = alignBytesPerRow(bytes_per_row);
    const dst_ptr: [*]u8 = @ptrCast(@alignCast(dst));
    for (0..height) |row| {
        const d = dst_ptr[row * padded_bytes_per_row ..][0..bytes_per_row];
        const s = src[row * bytes_per_row ..][0..bytes_per_row];
        @memcpy(d, s);
    }
}

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
pub const TextureFormat = @import("TextureFormat.zig").TextureFormat;
pub const Bindings = @import("Bindings.zig");
pub const BindGroupEntry = Bindings.BindGroupEntry;
pub const BindGroupLayoutEntry = @import("BindGroupLayoutEntry.zig");
pub const BindGroupLayoutEntryAccess = BindGroupLayoutEntry.BindGroupLayoutEntryAccess;
pub const BindGroupLayoutTextureEntry = BindGroupLayoutEntry.BindGroupLayoutTextureEntry;
pub const BindGroupLayoutBufferEntryType = BindGroupLayoutEntry.BindGroupLayoutBufferEntryType;
pub const BindGroupLayoutBufferEntry = BindGroupLayoutEntry.BindGroupLayoutBufferEntry;
pub const Shader = @import("Shader.zig");
pub const ShaderLanguage = Shader.ShaderLanguage;
pub const ShaderSource = Shader.ShaderSource;
pub const ShaderSourceContext = Shader.ShaderSourceContext;
pub const ShaderMap = Shader.ShaderMap;
pub const ComputePipeline = @import("ComputePipeline.zig");
pub const GPU = @import("GPU.zig");
