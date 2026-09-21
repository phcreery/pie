const ColorProfile = @import("ColorProfile.zig");
const std = @import("std");

pub const ShaderTypeEnum = enum {
    file,
    embed,
};

const ShaderSource = union(ShaderTypeEnum) {
    /// path string
    file: []const u8,
    /// inline string or use `@embedFile`
    embed: []const u8,
};

// uhh, this is duplicate....
pub const ShaderLanguage = enum {
    wgsl,
    spirv,
    glsl,
};

// uhh, this is duplicate....
pub const ShaderLanguageSource = union(ShaderLanguage) {
    wgsl: ShaderSource,
    spirv: ShaderSource,
    glsl: ShaderSource,
};

// uhh, this is duplicate....
pub const SocketType = enum {
    read,
    write,
    source,
    sink,
};

// uhh, this is also duplicate....
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
};

pub const SocketDesc = struct {
    name: []const u8,
    type: SocketType,
    format: TextureFormat,
    color_profile: ?ColorProfile = null,
};

pub const MAX_SOCKETS = 8;
pub const Sockets = [MAX_SOCKETS]?SocketDesc;

pub const NodeType = enum {
    compute,
    source,
    sink,
};

pub const NodeDesc = struct {
    type: NodeType, // TODO: infer from sockets
    shader: ?ShaderLanguageSource = null,
    name: []const u8,
    sockets: []const SocketDesc,
};
