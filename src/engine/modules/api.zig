//! API definitions for engine pipeline modules and nodes

const std = @import("std");
const gpu = @import("gpu");
pub const math = @import("math");
pub const ROI = @import("types").ROI;
pub const CFA = @import("types").CFA;

const ModuleApi = @import("types").ModuleApi;
pub const ShaderTypeEnum = ModuleApi.ShaderTypeEnum;
pub const ShaderSource = ModuleApi.ShaderSource;
pub const ShaderLanguage = ModuleApi.ShaderLanguage;
pub const ShaderLanguageSource = ModuleApi.ShaderLanguageSource;
pub const TextureFormat = ModuleApi.TextureFormat;
pub const NodeType = ModuleApi.NodeType;
pub const NodeDesc = ModuleApi.NodeDesc;
pub const Sockets = ModuleApi.Sockets;
pub const SocketType = ModuleApi.SocketType;
pub const SocketDesc = ModuleApi.SocketDesc;
pub const ParamType = ModuleApi.ParamType;
pub const ParamDesc = ModuleApi.ParamDesc;
pub const ModuleType = ModuleApi.ModuleType;
pub const ModuleDesc = ModuleApi.ModuleDesc;
pub const MAX_SOCKETS = ModuleApi.MAX_SOCKETS;

const ui = @import("types").ui;
pub const ParamUI = ui.ParamUI;
pub const Control = ui.Control;
pub const Slider = ui.Slider;
pub const Sliders = ui.Sliders;
pub const Combo = ui.Combo;

const pipeline = @import("../pipeline.zig");
pub const PipelineHandle = *pipeline.Pipeline; // sneaky
pub const ModuleHandle = pipeline.ModuleHandle;
pub const NodeHandle = pipeline.NodeHandle;
pub const Module = @import("../Module.zig");
pub const Node = @import("../Node.zig");
pub const Socket = @import("../Socket.zig");
pub const Connector = @import("../Connector.zig");
pub const Param = @import("../Param.zig");
pub const ImgParam = @import("../ImgParam.zig");
pub const HistoryConfig = @import("../histlist.zig").HistoryConfig;

comptime {
    std.debug.assert(gpu.MAX_BINDINGS == MAX_SOCKETS);
}
pub const MAX_PARAMS_PER_MODULE = 16;

/// A module can have multiple nodes.
/// They can have source and sink connectors as well, but the module must have
/// respective read_source and write_sink functions to handle them.
pub const ModuleDef = struct {
    desc: ModuleDesc,

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

pub fn copyToStaging(mapped: *anyopaque, src: []const u8, width: u32, height: u32, bpp: u32) void {
    gpu.data.copyDenseToStaging(mapped, src, width, height, bpp);
}

pub fn initParam(pipe: PipelineHandle, desc: ParamDesc, value: anytype) !Param {
    const param = try Param.init(pipe.allocator, desc, value);
    return param;
}

/// Write the initial value of a declared param. Params are created (zero
/// valued) when the module is registered, so this only sets the value.
pub fn initParamNamed(pipe: PipelineHandle, mod_handle: ModuleHandle, param_name: []const u8, value: anytype) !void {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    const param = try mod.getParamPtr(param_name);
    try param.set(value);
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

pub fn inheritSocket(pipe: PipelineHandle, mod: ModuleHandle, mod_socket_name: []const u8, node: NodeHandle, node_socket_name: []const u8) !void {
    return pipe.inheritSocket(mod, mod_socket_name, node, node_socket_name);
}

pub fn addNode(pipe: PipelineHandle, mod: ModuleHandle, comptime node_desc: NodeDesc) !NodeHandle {
    comptime var mutable_node_desc = node_desc;
    if (mutable_node_desc.shader) |shader| {
        mutable_node_desc.shader = comptime resolveShader(shader);
    }
    return pipe.addNode(mod, mutable_node_desc);
}

pub fn setNodeSocketRoi(pipe: PipelineHandle, node: NodeHandle, node_socket_name: []const u8, roi: ?ROI) !void {
    return pipe.setNodeSocketRoi(node, node_socket_name, roi);
}

pub fn setNodeRunSize(pipe: PipelineHandle, node: NodeHandle, run_size: ?ROI) !void {
    return pipe.setNodeRunSize(node, run_size);
}

pub fn connectNodesByName(pipe: PipelineHandle, src_node: NodeHandle, src_socket: []const u8, dst_node: NodeHandle, dst_socket: []const u8) !void {
    return pipe.connectNodesByName(src_node, src_socket, dst_node, dst_socket);
}

pub fn getModule(pipe: PipelineHandle, mod_handle: ModuleHandle) !*Module {
    return pipe.module_pool.getPtr(mod_handle);
}

pub fn getModSocket(pipe: PipelineHandle, mod_handle: ModuleHandle, socket_name: []const u8) !*Socket {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    return mod.getSocketPtr(socket_name);
}

pub fn copyModSocket(desc: ModuleDesc, socket_name: []const u8) !SocketDesc {
    for (desc.sockets) |sock| {
        if (std.mem.eql(u8, sock.name, socket_name)) {
            return sock;
        }
    }
    return error.SocketNotFound;
}

pub fn getSocketIndex(pipe: PipelineHandle, mod_handle: ModuleHandle, socket_name: []const u8) !usize {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    return mod.getSocketIndex(socket_name);
}

/// Resolve a shader declared in a zon descriptor: `.file` holds a path there
/// and is embedded at comptime into `.string`. Comptime only.
fn resolveShader(comptime declared: ShaderLanguageSource) ShaderLanguageSource {
    return switch (declared) {
        .wgsl => |src| .{ .wgsl = switch (src) {
            .file => |path| .{ .string = @embedFile(path) },
            .string => |code| .{ .string = code },
        } },
        .spirv => |src| .{ .spirv = switch (src) {
            .file => |path| .{ .string = @embedFile(path) },
            .string => |code| .{ .string = code },
        } },
        .glsl => |src| .{ .glsl = switch (src) {
            .file => |path| .{ .string = @embedFile(path) },
            .string => |code| .{ .string = code },
        } },
    };
}
