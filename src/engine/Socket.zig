const std = @import("std");
const api = @import("modules/api.zig");
const gpu = @import("gpu.zig");
pub const ROI = @import("ROI.zig");
const pipeline = @import("pipeline.zig");

pub const PrivateMembers = struct {
    // FOR PIPELINE OPERATION

    // for output sockets of modules
    connector_handle: ?pipeline.ConnectorHandle = null,

    // FOR GRAPH TRAVERSAL
    // for input sockets of modules
    connected_to_module: ?SocketConnection(pipeline.ModuleHandle) = null, // populated with pipe.connectModuleSocketsByHanldeName()

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
};

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

/// check if two socket descriptors are compatible for connection
/// that is, if the output socket can be connected to the input socket
pub fn areCompatible(output: *api.SocketDesc, input: *api.SocketDesc) bool {
    if (output.type.direction() != .output) return false;
    if (input.type.direction() != .input) return false;
    if (output.format != input.format) return false;
    // check that output ROI can satisfy input ROI
    if (input.roi) |input_roi| {
        if (output.roi) |output_roi| {
            if (output_roi.w != input_roi.w) return false;
            if (output_roi.h != input_roi.h) return false;
        } else {
            return false;
        }
    }
    return true;
}

/// check if two socket descriptors are similar
/// that is, if they have the same type, format, and ROI
/// used for copying socket descriptors between modules and nodes
pub fn areSimilar(sock_a: *api.SocketDesc, sock_b: *api.SocketDesc) bool {
    if (sock_a.type != sock_b.type) return false;
    if (sock_a.format != sock_b.format) return false;
    // check that ROI are the same
    // if (sock_a.roi) |a_roi| {
    //     if (sock_b.roi) |b_roi| {
    //         if (a_roi.w != b_roi.w) return false;
    //         if (a_roi.h != b_roi.h) return false;
    //     } else {
    //         return false;
    //     }
    // }
    return true;
}
