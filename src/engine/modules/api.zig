//! API definitions for engine pipeline modules and nodes
const std = @import("std");
const gpu = @import("../gpu.zig"); // TODO: we shouldn't need to expose this
pub const math = @import("../math/root.zig");

pub const ROI = @import("../ROI.zig");
pub const ImgParam = @import("../ImgParam.zig");
pub const CFA = @import("./shared/CFA.zig");

pub const pipeline = @import("../pipeline.zig");
pub const Pipeline = pipeline.Pipeline;
pub const PipelineHandle = *Pipeline; // sneaky
pub const ModuleHandle = pipeline.ModuleHandle;
pub const NodeHandle = pipeline.NodeHandle;
pub const Module = @import("../Module.zig");
pub const Node = @import("../Node.zig");
pub const Socket = @import("../Socket.zig");
pub const SocketConnection = Socket.SocketConnection;
pub const Param = @import("../Param.zig");
pub const Connector = @import("../Connector.zig");

pub const MAX_SOCKETS = gpu.MAX_BINDINGS;
pub const MAX_PARAMS_PER_MODULE = 16;

pub const SocketDesc = struct {
    name: []const u8,
    type: Socket.SocketType,
    format: gpu.TextureFormat,
    roi: ?ROI = null,
    color_profile: ?Connector.ColorProfile = null,

    private: Socket.PrivateMembers = .{},
};

pub const Sockets = [MAX_SOCKETS]?SocketDesc;

pub const NodeType = enum {
    compute,
    source,
    sink,
};

// vkdt dt_node_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/node.h#L19
pub const NodeDesc = struct {
    type: NodeType, // TODO: infer from sockets (e.g. if there is a socket with type source, it must be a source node)
    shader: ?gpu.ShaderSource = null,
    name: []const u8,
    run_size: ?ROI = null,
    sockets: Sockets,
};

pub const ModuleType = enum {
    compute,
    source,
    sink,
};

pub const ParamDesc = struct {
    name: []const u8,
    len: u32,
    typ: Param.Type,
};

/// UI hint for a module parameter. `name` must match the `ParamDesc` at the
/// same index in `ModuleDesc.params`, and the control must match the param
/// type (`slider`/`combo`/`checkbox` for i32/f32, `text` for str).
pub const ParamUI = struct {
    name: []const u8,
    control: Control,

    pub const Slider = struct {
        min: f32,
        max: f32,
        step: f32 = 0.0, // 0 = full precision (1/tick-resolution)
        /// optional unit suffix shown to the right of the value, e.g. " deg"
        suffix: ?[]const u8 = null,
    };

    pub const Control = union(enum) {
        /// float/int scalar slider (i32 values are truncated/stepped)
        slider: Slider,
        /// drop-down of string labels; value is the selected index (i32)
        combo: struct {
            items: []const []const u8,
        },
        /// boolean checkbox; value is 0/1 (i32)
        checkbox: void,
        /// single-line text input (str params)
        text: void,
        /// no interactive control, just a label showing the current value
        readonly: void,
    };
};

/// A module can have multiple nodes.
/// They can have source and sink connectors as well, but the module must have
/// respective read_source and write_sink functions to handle them.
/// vkdt dt_module_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/module.h#L107
/// vkdt dt_module_so_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/global.h#L62
pub const ModuleDesc = struct {
    name: []const u8,
    type: ModuleType,
    params: [MAX_PARAMS_PER_MODULE]?ParamDesc = @splat(null),

    /// UI hints for the editor; index-aligned with `params`. Entries may be
    /// null (params without a UI spec are shown read-only).
    params_ui: [MAX_PARAMS_PER_MODULE]?ParamUI = @splat(null),

    // The sockets describe the module's input and output interface
    // they can be null if the module has no input or output (sink or source only)
    sockets: Sockets,

    data: ?*anyopaque = null,

    // https://github.com/hanatos/vkdt/blob/1921eabfa2c87b90042dee676d5d3e34d8cbd5e1/src/pipe/global.c#L106
    initParams: ?*const fn (pipe: PipelineHandle, mod: ModuleHandle) anyerror!void = null,
    init: ?*const fn (allocator: std.mem.Allocator, io: std.Io, pipe: PipelineHandle, mod: ModuleHandle) anyerror!void = null,
    deinit: ?*const fn (allocator: std.mem.Allocator, pipe: PipelineHandle, mod: ModuleHandle) void = null,
    modifyOut: ?*const fn (pipe: PipelineHandle, mod: ModuleHandle) anyerror!void = null,
    createNodes: ?*const fn (pipe: PipelineHandle, mod: ModuleHandle) anyerror!void = null,
    readSource: ?*const fn (pipe: PipelineHandle, mod: ModuleHandle, mapped: *anyopaque) anyerror!void = null,
    writeSink: ?*const fn (allocator: std.mem.Allocator, io: std.Io, pipe: PipelineHandle, mod: ModuleHandle, mapped: *anyopaque) anyerror!void = null,
};

// ================
// PIPELINE HELPERS
// ================

pub fn compileShader(pipe: PipelineHandle, shader_source: gpu.ShaderSource) !gpu.Shader {
    const gpu_inst = pipe.gpu orelse return error.GPUNotInitialized;
    return gpu_inst.compileShader(shader_source);
}

pub fn initParam(pipe: PipelineHandle, desc: ParamDesc, value: anytype) !Param {
    const param = try Param.init(pipe.allocator, desc, value);
    return param;
}

pub fn initParamNamed(pipe: PipelineHandle, mod_handle: ModuleHandle, param_name: []const u8, value: anytype) !void {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    const idx = try mod.getParamIndex(param_name);
    const desc = mod.desc.params[idx].?; // TODO: handle null case better
    const param = try Param.init(pipe.allocator, desc, value);
    mod.params[idx] = param;
}

pub fn getParam(pipe: PipelineHandle, mod_handle: ModuleHandle, param_name: []const u8, T: type) !T {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    const idx = try mod.getParamIndex(param_name);
    const param = mod.params[idx].?; // TODO: handle null case better
    return param.get(T);
}

pub fn setParam(pipe: PipelineHandle, mod_handle: ModuleHandle, param_name: []const u8, T: type, value: T) !void {
    try pipe.setModuleParam(mod_handle, param_name, T, value);
}

pub fn copyConnector(pipe: PipelineHandle, mod: ModuleHandle, mod_socket_name: []const u8, node: NodeHandle, node_socket_name: []const u8) !void {
    return pipe.copyConnector(mod, mod_socket_name, node, node_socket_name);
}

/// Add a derived node to a module. Nodes are not recorded in history; this
/// forwards to the internal (non-recording) `addNodeDesc`.
pub fn addNodeDesc(pipe: PipelineHandle, mod: ModuleHandle, node_desc: NodeDesc) !NodeHandle {
    return pipe.addNodeDesc(mod, node_desc);
}

/// Connect two nodes by socket name. Forwards to `connectNodesName`.
pub fn connectNodesName(pipe: PipelineHandle, src_node: NodeHandle, src_socket: []const u8, dst_node: NodeHandle, dst_socket: []const u8) !void {
    return pipe.connectNodesName(src_node, src_socket, dst_node, dst_socket);
}

pub fn getModule(pipe: PipelineHandle, mod_handle: ModuleHandle) !*Module {
    return pipe.module_pool.getPtr(mod_handle);
}

pub fn getModSocket(pipe: PipelineHandle, mod_handle: ModuleHandle, socket_name: []const u8) !*SocketDesc {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    return mod.getSocketPtr(socket_name);
}

pub fn getSocketIndex(pipe: PipelineHandle, mod_handle: ModuleHandle, socket_name: []const u8) !usize {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    return mod.getSocketIndex(socket_name);
}
