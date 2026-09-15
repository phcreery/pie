const std = @import("std");
const api = @import("modules/api.zig");
const gpu = @import("gpu/root.zig");
pub const ROI = @import("ROI.zig");
const Connector = @import("Connector.zig");
const pipeline = @import("pipeline.zig");

name: []const u8,
type: SocketType,
format: gpu.TextureFormat,
roi: ?ROI = null,
color_profile: ?Connector.ColorProfile = null,

// FOR PIPELINE OPERATION

// for output sockets of modules
connector_handle: ?pipeline.ConnectorHandle = null,

// FOR GRAPH TRAVERSAL

// for input sockets of modules
// populated with pipe.connectModules()
connected_to_module: ?SocketConnection(pipeline.ModuleHandle) = null,

// for input sockets of nodes
// populated with pipe.connectNodesByName()
connected_to_node: ?SocketConnection(pipeline.NodeHandle) = null,

// for output sockets of modules
// populated with pipe.inheritSocket()
inherited_by_node: ?SocketConnection(pipeline.NodeHandle) = null,

// for input sockets of nodes
// populated with pipe.inheritSocket()
inherited_from_module: ?SocketConnection(pipeline.ModuleHandle) = null,

// offset in the upload or download staging buffer
// for source or sink sockets only
staging_offset: ?usize = null,
staging_ptr: ?*anyopaque = null,

const Self = @This();

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

pub fn SocketConnection(comptime TItem: type) type {
    return struct {
        item: TItem,
        socket_idx: usize,
    };
}

/// A live socket: the declared interface (copied from a `SocketDesc` when the
/// module is registered or the node is created) plus pipeline-owned runtime
/// state. Descriptors are never mutated at runtime; all state lives here.
pub fn fromDesc(desc: api.SocketDesc) Self {
    return .{
        .name = desc.name,
        .type = desc.type,
        .format = desc.format,
        .roi = desc.roi,
        .color_profile = desc.color_profile,
    };
}

/// Back to descriptor form, e.g. to seed a `NodeDesc` socket from a
/// module socket. Runtime state is dropped.
pub fn toDesc(self: Self) api.SocketDesc {
    return .{
        .name = self.name,
        .type = self.type,
        .format = self.format,
        .roi = self.roi,
        .color_profile = self.color_profile,
    };
}

/// check if two sockets are compatible for connection
/// that is, if the output socket can be connected to the input socket
pub fn areCompatible(output: *const Self, input: *const Self) bool {
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
    // color profile: the emitted profile must be accepted by the input
    // socket. Null/absent on either side means "don't care" -> compatible.
    if (!compatibleColorProfiles(output.color_profile, input.color_profile)) {
        return false;
    }
    return true;
}

fn compatibleColorProfiles(a: ?Connector.ColorProfile, b: ?Connector.ColorProfile) bool {
    const pa = a orelse return true;
    const pb = b orelse return true;
    return pa.acceptedBy(pb);
}

/// check if two sockets are similar
/// that is, if they have the same type, format, and ROI
/// used for copying socket descriptors between modules and nodes
pub fn areSimilar(sock_a: *const Self, sock_b: *const Self) bool {
    if (sock_a.type != sock_b.type) return false;
    if (sock_a.format != sock_b.format) return false;
    // color profile is part of the socket identity; "any" on either side
    // (or absent) matches. exact mismatches are not similar.
    if (!compatibleColorProfiles(sock_a.color_profile, sock_b.color_profile)) {
        return false;
    }
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
