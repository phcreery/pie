const wgpu = @import("wgpu_zig");
const TextureFormat = @import("TextureFormat.zig").TextureFormat;

texture: ?BindGroupLayoutTextureEntry = null,
buffer: ?BindGroupLayoutBufferEntry = null,

pub const BindGroupLayoutEntryAccess = enum {
    read,
    write,
};

pub const BindGroupLayoutTextureEntry = struct {
    format: TextureFormat,
    access: BindGroupLayoutEntryAccess,
};

pub const BindGroupLayoutBufferEntryType = enum {
    storage,
    uniform,
    // read_only_storage,

    pub fn toWGPUBufferBindingType(self: BindGroupLayoutBufferEntryType) wgpu.BindGroupLayout.BufferBindingType {
        return switch (self) {
            .storage => .storage,
            .uniform => .uniform,
            // .read_only_storage => .read_only_storage,
        };
    }
};

pub const BindGroupLayoutBufferEntry = struct {
    binding_type: BindGroupLayoutBufferEntryType,
};
