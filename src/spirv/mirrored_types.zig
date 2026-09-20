const std = @import("std");

pub const SocketType = enum {
    read,
    write,
    source,
    sink,
};

// mirrors gpu.TextureFormat
pub const TextureFormat = enum {
    rgba16float,
    rgba16uint,
    r8uint,
    r16uint,
    r16float,
    rggb32float,
    rggb16uint,

    pub fn toSpirvImageFormat(self: TextureFormat) std.lang.Type.Spirv.Image.Format {
        return switch (self) {
            .rgba16float => .rgba16f,
            .rgba16uint => .rgba16u,
            .r8uint => .unknown,
            .r16uint => .unknown,
            .r16float => .unknown,

            // special cases: bayer mosaic stored single-channel
            .rggb32float => .r32f,
            .rggb16uint => .unknown,
        };
    }

    pub fn toBaseType(self: TextureFormat) type {
        return switch (self) {
            .rgba16float => f16,
            .rgba16uint => u16,
            .r8uint => u8,
            .r16uint => u16,
            .r16float => f16,

            // special cases: bayer mosaic stored single-channel
            .rggb32float => f32,
            .rggb16uint => u16,
        };
    }
};

const SocketDescZon = struct {
    name: []const u8,
    type: SocketType,
    format: TextureFormat,

    pub fn toSpirvUsage(self: SocketDescZon) std.lang.Type.Spirv.Image.Usage {
        // const T = self.format.toBaseType();
        return switch (self.type) {
            // .read => .{ .sampled = T },
            .read => .{ .sampled = f32 },
            // 'storage' field value must be a 32-bit int, 64-bit int or 32-bit float under the 'vulkan' os
            .write => .{ .storage = f32 },
            .source, .sink => unreachable,
        };
    }
};

pub const ShaderTypeEnum = enum {
    file,
    embed,
};

// mirrors api.ShaderSource
pub const ShaderSource = union(ShaderTypeEnum) {
    file: []const u8,
    embed: []const u8,
};

pub const ShaderLanguage = enum {
    wgsl,
    spirv,
    glsl,
};

// mirrors api.ShaderLanguageSource
pub const ShaderLanguageSource = union(ShaderLanguage) {
    wgsl: ShaderSource,
    spirv: ShaderSource,
    glsl: ShaderSource,
};

pub const NodeDescZon = struct {
    shader: ShaderLanguageSource,
    name: []const u8,
    sockets: []const SocketDescZon,
};
