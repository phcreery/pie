const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu/root.zig");
const pipeline = @import("pipeline.zig");
const Socket = @import("Socket.zig");
const slog = std.log.scoped(.node);

/// Node type, copied from `NodeDesc` at creation.
type: api.NodeType,
name: []const u8,
shader_source: ?gpu.ShaderSource,
run_size: ?api.ROI,

/// Handle of the module this node belongs to.
mod: pipeline.ModuleHandle,

/// Live sockets, copied from the `NodeDesc` when the node is created. All
/// runtime socket state (roi, private members) lives here.
sockets: [api.MAX_SOCKETS]?Socket = @splat(null),

shader: ?gpu.Shader = null,
compute_pipeline: ?gpu.ComputePipeline = null,
bindings: ?gpu.Bindings = null,

/// debug: number of times this node has been enqueued (dispatched) by the
/// pipeline. Useful for tests verifying dirty-region invalidation.
run_count: u32 = 0,

const Self = @This();

pub fn init(
    pipe: *pipeline.Pipeline,
    mod: pipeline.ModuleHandle,
    desc: api.NodeDesc,
) !Self {
    _ = pipe;

    var self = Self{
        .type = desc.type,
        .name = desc.name,
        .shader_source = desc.shader,
        .run_size = desc.run_size,
        .mod = mod,
    };
    // copy the declared interface into live sockets
    for (desc.sockets, 0..) |maybe_sock, i| {
        if (maybe_sock) |sock| {
            self.sockets[i] = Socket.fromDesc(sock);
        }
    }
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.bindings) |*bindings| {
        bindings.deinit();
    }
    if (self.compute_pipeline) |*shader| {
        shader.deinit();
    }
}

pub fn getSocketIndex(node: *const Self, name: []const u8) !usize {
    for (node.sockets, 0..) |sock, idx| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return idx;
            }
        }
    }
    return error.NodeSocketNotFound;
}
pub fn getSocketPtr(node: *Self, name: []const u8) !*Socket {
    const idx = try node.getSocketIndex(name);
    if (node.sockets[idx]) |*sock| {
        return sock;
    }
    return error.NodeSocketNotFound;
}
