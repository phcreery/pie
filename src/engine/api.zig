const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const pipeline = @import("pipeline.zig"); // circular import?

pub const SocketType = enum {
    read,
    write,
    source,
    // sink

    pub fn toShaderPipeConnType(self: SocketType) gpu.ShaderPipeConnType {
        return switch (self) {
            .read => gpu.ShaderPipeConnType.read,
            .write => gpu.ShaderPipeConnType.write,
            else => unreachable,
        };
    }
};

pub const SocketDesc = struct {
    name: []const u8,
    type: SocketType,
    format: gpu.TextureFormat,
    roi: ?ROI,
};

pub const NodeType = enum {
    compute,
    source,
};

// vkdt dt_node_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/node.h#L19
pub const NodeDesc = struct {
    type: NodeType,
    shader_code: []const u8,
    entry_point: []const u8,
    run_size: ?ROI,
    // connectors: []Connector,
    input_sock: SocketDesc,
    output_sock: SocketDesc,
};

pub const ModuleType = enum {
    compute,
    source,
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
    // nodes: anyerror![]Node,
    // enabled: bool,

    // Use the first and last nodes connectors as module connectors
    // connectors: []Connector,
    // The sockets describe the module's input and output interface
    // they can be null if the module has no input or output (sink or source only)
    input_sock: ?SocketDesc,
    output_sock: ?SocketDesc,

    // param_ui: []u8,
    // param_uniform: []u8,

    // uniform_offset: usize,
    // uniform_size: usize,

    init: ?*const fn (mod: *pipeline.Module) anyerror!void,
    deinit: ?*const fn (mod: *pipeline.Module) anyerror!void,
    create_nodes: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module) anyerror!void,
    read_source: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module, allocator: *gpu.GPUAllocator) anyerror!void,
    // write_sink: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module, alloc: gpu.GPUAllocator) anyerror!void,
    modify_roi_out: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module) anyerror!void,
};
