const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu");
const pipeline = @import("pipeline.zig");
const Socket = @import("Socket.zig");
const slog = std.log.scoped(.node);

type: api.NodeType,
name: []const u8,
shader_source: ?gpu.ShaderSource,
run_size: ?api.ROI,

/// Handle of the module this node belongs to.
mod: pipeline.ModuleHandle,

/// Sockets copied from the `NodeDesc` when the node is created.
/// All runtime socket state lives here.
sockets: [api.MAX_SOCKETS]?Socket = @splat(null),

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

    const shader_source: ?gpu.ShaderSource = if (desc.shader) |declared| switch (declared) {
        .wgsl => |src| gpu.ShaderSource{ .wgsl = switch (src) {
            .file => unreachable,
            .string => |code| code,
        } },
        .spirv => |src| gpu.ShaderSource{ .spirv = switch (src) {
            .file => unreachable,
            .string => |code| code,
        } },
        .glsl => |src| gpu.ShaderSource{ .glsl = switch (src) {
            .file => unreachable,
            .string => |code| code,
        } },
    } else null;

    var self = Self{
        .type = desc.type,
        .name = desc.name,
        .shader_source = shader_source,
        .run_size = null,
        .mod = mod,
    };
    // copy the declared interface into live sockets
    for (desc.sockets, 0..) |sock, i| {
        self.sockets[i] = Socket.fromDesc(sock);
    }
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.bindings) |*bindings| {
        bindings.deinit();
    }
    if (self.compute_pipeline) |*comp_pipe| {
        comp_pipe.deinit();
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
