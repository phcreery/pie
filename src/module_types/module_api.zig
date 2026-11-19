const ui = @import("ui_types").ui;
pub const ParamUI = ui.ParamUI;
const ColorProfile = @import("ColorProfile.zig");
pub const Resource = @import("gpu_types").Resource;
pub const DataType = @import("gpu_types").DataType;

/// How a parameter's value bytes are encoded.
pub const ParamType = enum {
    i32,
    f32,
    str,
    enum_u32,
};

/// A module parameter: its name, element count and element type. Part of the
/// module API — `ModuleDesc.params` is an array of these.
pub const ParamDesc = struct {
    name: []const u8,
    len: u32,
    typ: ParamType,
    /// Names of the `enum_u32` values, in value order.
    enum_names: []const []const u8 = &.{},
};

pub const ShaderTypeEnum = enum {
    file,
    string,
};

const ShaderSource = union(ShaderTypeEnum) {
    /// path string
    file: []const u8,
    /// inline string or use `@embedFile`
    string: []const u8,
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

pub const SocketDesc = struct {
    name: []const u8,
    access: SocketType,
    resource: Resource,
    datatype: DataType,
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

pub const ModuleType = enum {
    compute,
    source,
    sink,
};

pub const ModuleDesc = struct {
    name: []const u8,
    type: ModuleType,
    params: []const ParamDesc,

    /// UI hints for the editor; index-aligned with `params`.
    params_ui: []const ParamUI,

    // The sockets describe the module's input and output interface
    sockets: []const SocketDesc,
};
