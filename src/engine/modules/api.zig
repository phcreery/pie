/// API definitions for engine pipeline modules and nodes
const std = @import("std");
const gpu = @import("../gpu.zig");
pub const ROI = @import("../ROI.zig");
pub const pipeline = @import("../pipeline.zig");
pub const Module = @import("../Module.zig");
pub const Node = @import("../Node.zig");
pub const Pipeline = pipeline.Pipeline;
// const slog = std.log.scoped(.api);

pub const MAX_SOCKETS = gpu.MAX_BINDINGS;

pub const Direction = enum {
    input,
    output,
};

pub const SocketType = enum {
    read,
    write,
    source,
    sink,

    pub fn toShaderPipeBindGroupLayoutEntryAccess(self: SocketType) gpu.BindGroupLayoutEntryAccess {
        return switch (self) {
            .read => gpu.BindGroupLayoutEntryAccess.read,
            .write => gpu.BindGroupLayoutEntryAccess.write,
            else => unreachable,
        };
    }

    pub fn direction(self: SocketType) Direction {
        return switch (self) {
            .read => Direction.input,
            .write => Direction.output,
            .source => Direction.output,
            .sink => Direction.input,
        };
    }
};

pub fn SocketConnection(comptime TItem: type) type {
    return struct {
        item: TItem,
        socket_idx: usize,
    };
}

pub const SocketDesc = struct {
    name: []const u8,
    type: SocketType,
    format: gpu.TextureFormat,
    roi: ?ROI = null,

    private: Private = .{},

    const Private = struct {
        conn_handle: ?pipeline.ConnectorHandle = null,

        // FOR GRAPH TRAVERSAL
        // for input sockets of modules
        // connected_to_module: ?pipeline.ModuleHandle = null, // populated with pipe.connectModules()
        // connected_to_module: ?*Module = null, // populated with pipe.connectModules()
        // connected_to_module_socket_idx: ?usize = null,
        connected_to_module: ?SocketConnection(*Module) = null, // populated with pipe.connectModules()

        // for input sockets of nodes
        // connected_to_node: ?pipeline.NodeHandle = null, // populated with pipe.connectNodes()
        // connected_to_node_socket_idx: ?usize = null,
        connected_to_node: ?SocketConnection(pipeline.NodeHandle) = null, // populated with pipe.connectNodes()

        // for output sockets of modules
        // associated_with_node: ?pipeline.NodeHandle = null, // populated with pipe.copyConnector()
        // associated_with_node_socket_idx: ?usize = null,
        associated_with_node: ?SocketConnection(pipeline.NodeHandle) = null, // populated with pipe.copyConnector()
        // for input sockets of nodes
        // associated_with_module: ?pipeline.ModuleHandle = null, // populated with pipe.copyConnector()
        // associated_with_module: ?*Module = null, // populated with pipe.copyConnector()
        // associated_with_module_socket_idx: ?usize = null,
        associated_with_module: ?SocketConnection(*Module) = null, // populated with pipe.copyConnector()

        // offset in the upload staging buffer
        // for source or sink offsets
        staging_offset: ?usize = null,
        staging: ?*anyopaque = null,
    };

    pub fn getConnectedNode(self: *const SocketDesc) ?SocketConnection(pipeline.NodeHandle) {
        if (self.private.connected_to_node) |src_node_handle_connection| {
            return src_node_handle_connection;
        } else if (self.private.associated_with_module) |assoc_mod| {
            // if the node is not directly connected to another node,
            // check if it is linked to a module then check what that
            // module is connected to and then traverse to the node that
            // is linked to that socket and connect to that node
            // slog.debug("Socket {s} is associated with module {s}", .{ self.name, assoc_mod.item.desc.name });
            const assoc_mod_socket = assoc_mod.item.desc.sockets[assoc_mod.socket_idx] orelse unreachable;
            if (assoc_mod_socket.private.connected_to_module) |connected_to_mod| {
                // slog.debug("Associated module socket {s} is connected to module {s}", .{ assoc_mod_socket.name, connected_to_mod.item.desc.name });
                const connected_to_mod_socket = connected_to_mod.item.desc.sockets[connected_to_mod.socket_idx] orelse unreachable;
                if (connected_to_mod_socket.private.associated_with_node) |src_node_handle_connection| {
                    return src_node_handle_connection;
                }
            }
        }
        return null;
    }
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
    shader_code: []const u8,
    entry_point: []const u8,
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
    // enabled: bool,

    // Use the first and last nodes connectors as module connectors
    // connectors: []Connector,
    // The sockets describe the module's input and output interface
    // they can be null if the module has no input or output (sink or source only)
    // input_socket: ?SocketDesc = null,
    // output_socket: ?SocketDesc = null,
    sockets: Sockets,

    // param_ui: []u8,
    // param_uniform: []u8,

    // uniform_offset: usize,
    // uniform_size: usize,

    init: ?*const fn (mod: *Module) anyerror!void = null,
    deinit: ?*const fn (mod: *Module) anyerror!void = null,
    createNodes: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module) anyerror!void = null,
    readSource: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module, mapped: *anyopaque) anyerror!void = null,
    writeSink: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module, mapped: *anyopaque) anyerror!void = null,
    modifyROIOut: ?*const fn (pipe: *pipeline.Pipeline, mod: *Module) anyerror!void = null,
};

pub fn addModule(pipe: *pipeline.Pipeline, module_desc: ModuleDesc) !*Module {
    return pipe.addModule(module_desc);
}

pub fn addNode(pipe: *pipeline.Pipeline, mod: *Module, node_desc: NodeDesc) !pipeline.NodeHandle {
    return pipe.addNode(mod, node_desc);
}
pub fn copyConnector(
    pipe: *pipeline.Pipeline,
    mod: *Module,
    mod_socket_name: []const u8,
    node: pipeline.NodeHandle,
    node_socket_name: []const u8,
) !void {
    return pipe.copyConnector(mod, mod_socket_name, node, node_socket_name);
}
