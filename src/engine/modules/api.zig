/// API definitions for engine pipeline modules and nodes
const std = @import("std");
const gpu = @import("../gpu.zig");

pub const ROI = @import("../ROI.zig");
pub const pipeline = @import("../pipeline.zig");
pub const Module = @import("../Module.zig");
pub const Node = @import("../Node.zig");
pub const Socket = @import("../Socket.zig");
pub const Param = @import("../Param.zig");
pub const Pipeline = pipeline.Pipeline;
pub const ModuleHandle = pipeline.ModuleHandle;
pub const NodeHandle = pipeline.NodeHandle;

pub const CFA = @import("./shared/CFA.zig");

pub const MAX_SOCKETS = gpu.MAX_BINDINGS;
pub const MAX_PARAMS_PER_MODULE = 16;

pub fn SocketConnection(comptime TItem: type) type {
    return struct {
        item: TItem,
        socket_idx: usize,
    };
}

pub const SocketDesc = struct {
    name: []const u8,
    type: Socket.SocketType,
    format: gpu.TextureFormat,
    roi: ?ROI = null,

    private: Socket.PrivateMembers = .{},
};

pub const Sockets = [MAX_SOCKETS]?SocketDesc;

// Can we make NodeDesc a tagged union instead?
pub const NodeType = enum {
    compute,
    source,
    sink,
};

// vkdt dt_node_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/node.h#L19
pub const NodeDesc = struct {
    type: NodeType, // TODO: infer from sockets (e.g. if there is a socket with type source, it must be a source node)
    shader: ?[]const u8 = null,
    // shader: ?gpu.Shader = null,
    name: []const u8,
    run_size: ?ROI = null,
    sockets: Sockets,
};

pub const ModuleType = enum {
    compute,
    source,
    sink,
};

/// Module structure
///
/// A module can have multiple nodes.
///
/// For now, we assume a module has a single input and a single output.
/// They can have source and sink connectors as well, but the module must have
/// respective read_source and write_sink functions to handle them.
///
/// vkdt dt_module_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/module.h#L107
/// vkdt dt_module_so_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/global.h#L62
pub const ModuleDesc = struct {
    name: []const u8,
    type: ModuleType,
    params: ?[MAX_PARAMS_PER_MODULE]?Param = null,

    // The sockets describe the module's input and output interface
    // they can be null if the module has no input or output (sink or source only)
    sockets: Sockets,

    data: ?*anyopaque = null,

    init: ?*const fn (allocator: std.mem.Allocator, pipe: *Pipeline, mod: ModuleHandle) anyerror!void = null,
    deinit: ?*const fn (allocator: std.mem.Allocator, pipe: *Pipeline, mod: ModuleHandle) void = null,
    createNodes: ?*const fn (pipe: *Pipeline, mod: ModuleHandle) anyerror!void = null,
    readSource: ?*const fn (pipe: *Pipeline, mod: ModuleHandle, mapped: *anyopaque) anyerror!void = null,
    writeSink: ?*const fn (allocator: std.mem.Allocator, pipe: *Pipeline, mod: ModuleHandle, mapped: *anyopaque) anyerror!void = null,
    modifyROIOut: ?*const fn (pipe: *Pipeline, mod: ModuleHandle) anyerror!void = null,
};

/// PIPELINE HELPERS
pub fn compileShader(pipe: *Pipeline, shader_code: []const u8) !gpu.Shader {
    const gpu_inst = pipe.gpu orelse return error.GPUNotInitialized;
    return gpu.Shader.compile(gpu_inst, shader_code, .{});
}

pub fn addNode(pipe: *Pipeline, mod: ModuleHandle, node_desc: NodeDesc) !NodeHandle {
    return pipe.addNode(mod, node_desc);
}

pub fn copyConnector(pipe: *Pipeline, mod: ModuleHandle, mod_socket_name: []const u8, node: NodeHandle, node_socket_name: []const u8) !void {
    return pipe.copyConnector(mod, mod_socket_name, node, node_socket_name);
}

pub fn getModule(pipe: *Pipeline, mod_handle: ModuleHandle) !*Module {
    return pipe.module_pool.getPtr(mod_handle);
}

pub fn getModSocket(pipe: *Pipeline, mod_handle: ModuleHandle, socket_name: []const u8) !*SocketDesc {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    return mod.getSocketPtr(socket_name);
}

pub fn getSocketIndex(pipe: *Pipeline, mod_handle: ModuleHandle, socket_name: []const u8) !usize {
    const mod = try pipe.module_pool.getPtr(mod_handle);
    return mod.getSocketIndex(socket_name);
}
