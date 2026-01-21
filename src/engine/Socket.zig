const std = @import("std");
const api = @import("modules/api.zig");
const gpu = @import("gpu.zig");
pub const ROI = @import("ROI.zig");
const pipeline = @import("pipeline.zig");

name: []const u8,
type: SocketType,
format: gpu.TextureFormat,
roi: ?ROI = null,

// for output sockets of modules
connector_handle: ?pipeline.ConnectorHandle = null,

// FOR GRAPH TRAVERSAL
// for input sockets of modules
connected_to_module: ?SocketConnection(pipeline.ModuleHandle) = null, // populated with pipe.connectModulesName()

// for input sockets of nodes
connected_to_node: ?SocketConnection(pipeline.NodeHandle) = null, // populated with pipe.connectNodesName()

// for output sockets of modules
associated_with_node: ?SocketConnection(pipeline.NodeHandle) = null, // populated with pipe.copyConnector()
// for input sockets of nodes
associated_with_module: ?SocketConnection(pipeline.ModuleHandle) = null, // populated with pipe.copyConnector()

// offset in the upload or download staging buffer
// for source or sink sockets only
staging_offset: ?usize = null,
staging_ptr: ?*anyopaque = null,

pub fn SocketConnection(comptime TItem: type) type {
    return struct {
        item: TItem,
        socket_idx: usize,
    };
}

pub const Direction = enum {
    input,
    output,
};

pub const SocketType = enum {
    read,
    write,
    source,
    sink,

    pub fn toComputePipelineBindGroupLayoutEntryAccess(self: SocketType) gpu.BindGroupLayoutEntryAccess {
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
