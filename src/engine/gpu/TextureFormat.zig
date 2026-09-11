const wgpu = @import("wgpu_zig");

pub const TextureFormat = enum {
    rgba16float,
    rgba16uint,
    r8uint,
    r16uint,
    r16float,

    // special cases
    // NOTE: rggb* are *semantic* formats: the data is RGGB bayer mosaic, but
    // it is stored single-channel (one photosite per texel) on the GPU. ROI is
    // the true photosite size (w x h). Shaders decode the bayer phase from
    // coords; WGSL declares the underlying storage type (not "rggb").
    //
    // The float bayer stage is stored as r32_float, not r16_float: r16float is
    // not a WebGPU core storage-texture format while r32float is. The
    // u16 raw input stays rggb16uint (r16_uint, which IS core-spec).
    rggb32float,
    rggb16uint,

    pub fn toWGPUFormat(self: TextureFormat) wgpu.Texture.Format {
        return switch (self) {
            .rgba16float => .rgba16_float,
            .rgba16uint => .rgba16_uint,
            .r8uint => .r8_uint,
            .r16uint => .r16_uint,
            .r16float => .r16_float,

            // special cases: bayer mosaic stored single-channel
            .rggb32float => .r32_float,
            .rggb16uint => .r16_uint,
        };
    }

    pub fn toWGPUSampleType(self: TextureFormat) wgpu.BindGroupLayout.TextureSampleType {
        return switch (self) {
            .rgba16float => .float,
            .rgba16uint => .uint,
            .r8uint => .uint,
            .r16uint => .uint,
            .r16float => .float,

            // special cases: single-channel bayer
            .rggb32float => .float,
            .rggb16uint => .uint,
        };
    }

    // TODO: make to following functions comptime accessible

    /// bytes per pixel
    pub fn bpp(self: TextureFormat) u32 {
        return self.nchannels() * self.baseTypeSize();
    }

    /// number of channels
    pub fn nchannels(self: TextureFormat) u32 {
        return switch (self) {
            .rgba16float => 4,
            .rgba16uint => 4,
            .r8uint => 1,
            .r16uint => 1,
            .r16float => 1,

            // special cases: single-channel bayer mosaic
            .rggb32float => 1,
            .rggb16uint => 1,
        };
    }

    pub fn baseTypeSize(self: TextureFormat) u32 {
        return switch (self) {
            .rgba16float => @sizeOf(f16),
            .rgba16uint => @sizeOf(u16),
            .r8uint => @sizeOf(u8),
            .r16uint => @sizeOf(u16),
            .r16float => @sizeOf(f16),

            // special cases
            .rggb32float => @sizeOf(f32),
            .rggb16uint => @sizeOf(u16),
        };
    }
};
