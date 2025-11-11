/// API definitions for engine pipeline modules and nodes
const std = @import("std");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");
const pipeline = @import("pipeline.zig");

pub const MAX_SOCKETS = 8;

pub const Direction = enum {
    input,
    output,
};

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

    pub fn direction(self: SocketType) Direction {
        return switch (self) {
            .read => Direction.input,
            .write => Direction.output,
            .source => Direction.output,
            // .sink => Direction.input,
        };
    }
};

pub const SocketDesc = struct {
    name: []const u8,
    type: SocketType,
    format: gpu.TextureFormat,
    roi: ?ROI = null,

    private: Private = .{},

    const Private = struct {
        // FOR OUTPUT SOCKETS
        conn_handle: ?pipeline.ConnectorHandle = null,

        // FOR INPUT SOCKETS
        connected_to: ?*pipeline.Node = null, // populated with graph.connect_nodes()

        // FOR INPUT SOCKETS THAT ARE THE FIRST IN A MODULE OR OUTPUT SOCKETS THAT ARE THE LAST IN A MODULE
        associated_with: ?*pipeline.Module = null, // populated with socket.associated_with()
    };
};

pub const Sockets = [MAX_SOCKETS]?SocketDesc;

pub const NodeType = enum {
    compute,
    source,
};

// vkdt dt_node_t https://github.com/hanatos/vkdt/blob/632165bb3cf7d653fa322e3ffc023bdb023f5e87/src/pipe/node.h#L19
pub const NodeDesc = struct {
    type: NodeType, // TODO: infer from sockets (e.g. if there is a socket with type source, it must be a source node)
    shader_code: []const u8,
    entry_point: []const u8,
    run_size: ?ROI,
    sockets: Sockets,
    // sockets: std.ArrayList(SocketDesc),
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
    // enabled: bool,

    // Use the first and last nodes connectors as module connectors
    // connectors: []Connector,
    // The sockets describe the module's input and output interface
    // they can be null if the module has no input or output (sink or source only)
    input_sock: ?SocketDesc = null,
    output_sock: ?SocketDesc = null,

    // param_ui: []u8,
    // param_uniform: []u8,

    // uniform_offset: usize,
    // uniform_size: usize,

    init: ?*const fn (mod: *pipeline.Module) anyerror!void = null,
    deinit: ?*const fn (mod: *pipeline.Module) anyerror!void = null,
    createNodes: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module) anyerror!void = null,
    readSource: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module, allocator: *gpu.GPUAllocator) anyerror!void = null,
    // write_sink: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module, alloc: gpu.GPUAllocator) anyerror!void = null,
    modifyROIOut: ?*const fn (pipe: *pipeline.Pipeline, mod: *pipeline.Module) anyerror!void = null,
};
