const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.node);

desc: api.NodeDesc,
mod: pipeline.ModuleHandle,
shader: ?gpu.Shader = null,
compute_pipeline: ?gpu.ComputePipeline = null,
bindings: ?gpu.Bindings = null,

const Self = @This();

pub fn init(
    pipe: *pipeline.Pipeline,
    mod: pipeline.ModuleHandle,
    desc: api.NodeDesc,
) !Self {
    _ = pipe;

    return Self{
        .desc = desc,
        .mod = mod,
    };
}

pub fn deinit(self: *Self) void {
    if (self.bindings) |*bindings| {
        bindings.deinit();
    }
    if (self.compute_pipeline) |*shader| {
        shader.deinit();
    }
}

pub fn getSocketHandleNamed(node: *Self, pipe: *pipeline.Pipeline, name: []const u8) ?*api.SocketHandle {
    for (node.desc.sockets) |maybe_sock_handle| {
        if (maybe_sock_handle) |sock_handle| {
            const socket = try pipe.socket_pool.getPtr(sock_handle);
            if (std.mem.eql(u8, socket.name, name)) {
                return sock_handle;
            }
        }
    }
    return null;
}

pub fn getSocketPtrNamed(node: *Self, pipe: *pipeline.Pipeline, name: []const u8) ?*api.Socket {
    for (node.desc.sockets) |maybe_sock_handle| {
        if (maybe_sock_handle) |sock_handle| {
            const socket = try pipe.socket_pool.getPtr(sock_handle);
            if (std.mem.eql(u8, socket.name, name)) {
                return socket;
            }
        }
    }
    return null;
}
