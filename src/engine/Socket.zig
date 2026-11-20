const std = @import("std");
const api = @import("modules/api.zig");
const gpu = @import("gpu");
const ROI = @import("module_types").ROI;
const ColorProfile = @import("module_types").ColorProfile;
const Resource = @import("module_types").Resource;
const DataType = @import("module_types").DataType;
const pipeline = @import("pipeline.zig");
const util = @import("util.zig");

name: []const u8,
type: SocketType,
resource: Resource,
datatype: DataType,
roi: ?ROI = null,
color_profile: ?ColorProfile = null,

// FOR PIPELINE OPERATION

/// for output sockets of modules
connector_handle: ?pipeline.ConnectorHandle = null,

// FOR GRAPH TRAVERSAL

/// for input sockets of modules
/// populated with pipe.connectModules()
connected_to_module: ?SocketConnection(pipeline.ModuleHandle) = null,

/// for input sockets of nodes
/// populated with pipe.connectNodesByName()
connected_to_node: ?SocketConnection(pipeline.NodeHandle) = null,

/// for output sockets of modules
/// populated with pipe.inheritSocket()
inherited_by_node: ?SocketConnection(pipeline.NodeHandle) = null,

/// for sockets of nodes that were inherited from a module socket
/// populated with pipe.inheritSocket()
inherited_from_module: ?SocketConnection(pipeline.ModuleHandle) = null,

/// offset in the upload or download staging buffer
/// for source or sink sockets only
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
    const stype = util.castEnum(SocketType, desc.access);
    return .{
        .name = desc.name,
        .type = stype,
        .resource = desc.resource,
        .datatype = desc.datatype,
        .color_profile = desc.color_profile,
    };
}

/// Back to descriptor form, e.g. to seed a `NodeDesc` socket from a
/// module socket. Runtime state is dropped.
pub fn toDesc(self: Self) api.SocketDesc {
    const stype = util.castEnum(api.SocketType, self.type);
    return .{
        .name = self.name,
        .access = stype,
        .resource = self.resource,
        .datatype = self.datatype,
        .color_profile = self.color_profile,
    };
}

/// check if two sockets are compatible for connection
/// that is, if the output socket can be connected to the input socket
pub fn areCompatible(output: *const Self, input: *const Self) bool {
    if (output.type.direction() != .output) return false;
    if (input.type.direction() != .input) return false;
    if (output.resource != .any and input.resource != .any and output.resource != input.resource) return false;
    if (output.datatype != .any and input.datatype != .any and output.datatype != input.datatype) return false;
    // The output extent must satisfy the input extent. For buffers, w is the
    // element count and h is the element stride.
    if (input.roi) |input_roi| {
        if (output.roi) |output_roi| {
            if (output_roi.w != input_roi.w) return false;
            if (output_roi.h != input_roi.h) return false;
        } else {
            return false;
        }
    }
    // Buffers carry no color profile.
    if (output.resource == .buffer or input.resource == .buffer) return true;
    // The emitted profile must be accepted by the input socket. A null profile
    // on either side means "do not care".
    if (!compatibleColorProfiles(output.color_profile, input.color_profile)) {
        return false;
    }
    return true;
}

fn compatibleColorProfiles(a: ?ColorProfile, b: ?ColorProfile) bool {
    const pa = a orelse return true;
    const pb = b orelse return true;
    return pa.acceptedBy(pb);
}

/// check if two sockets are similar
/// that is, if they have the same type, format, and ROI
/// used for copying socket descriptors between modules and nodes
pub fn areSimilar(sock_a: *const Self, sock_b: *const Self) bool {
    if (sock_a.type != sock_b.type) return false;
    if (sock_a.resource != .any and sock_b.resource != .any and sock_a.resource != sock_b.resource) return false;
    if (sock_a.datatype != .any and sock_b.datatype != .any and sock_a.datatype != sock_b.datatype) return false;
    if (sock_a.resource == .buffer or sock_b.resource == .buffer) return true;
    // The color profile is part of the socket identity. "any" on either side,
    // or an absent profile, matches.
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

test "buffer and texture sockets are not compatible" {
    const tex = Self{
        .name = "tex",
        .type = .write,
        .resource = .rgba,
        .datatype = .f16,
        .roi = .{ .w = 1, .h = 1 },
    };
    const buf = Self{
        .name = "buf",
        .type = .read,
        .resource = .buffer,
        .datatype = .u32,
        .roi = .{ .w = 4, .h = 1 },
    };
    try std.testing.expect(!areCompatible(&tex, &buf));
}

test "wildcard resource connects to a buffer" {
    const out = Self{
        .name = "out",
        .type = .write,
        .resource = .any,
        .datatype = .any,
        .roi = .{ .w = 4, .h = 1 },
    };
    const in = Self{
        .name = "in",
        .type = .read,
        .resource = .buffer,
        .datatype = .u32,
        .roi = .{ .w = 4, .h = 1 },
    };
    try std.testing.expect(areCompatible(&out, &in));
}
