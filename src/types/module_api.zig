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

pub const ShaderLanguage = enum {
    wgsl,
    spirv,
    glsl,
};

pub const ShaderLanguageSource = union(ShaderLanguage) {
    wgsl: ShaderSource,
    spirv: ShaderSource,
    glsl: ShaderSource,
};

pub const SocketType = enum {
    read,
    write,
    source,
    sink,
};

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

pub const SocketDescZon = struct {
    name: []const u8,
    type: SocketType,
    format: TextureFormat,
};

pub const NodeDescZon = struct {
    shader: ShaderLanguageSource,
    name: []const u8,
    sockets: []const SocketDescZon,
};
