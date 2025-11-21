const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.node);

desc: api.NodeDesc,
mod: *Module,
shader: ?gpu.ShaderPipe = null,
bindings: ?gpu.Bindings = null,

const Self = @This();

pub fn init(
    pipe: *pipeline.Pipeline,
    mod: *Module,
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
    if (self.shader) |*shader| {
        shader.deinit();
    }
}

pub fn getSocket(node: *Self, name: []const u8) ?api.SocketDesc {
    for (node.desc.sockets) |sock| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                slog.info("Found socket for node {s}, connector {s}", .{ node.desc.entry_point, name });
                return s;
            }
        }
    }
    return null;
}
pub fn getSocketIndex(node: *Self, name: []const u8) ?usize {
    for (node.desc.sockets, 0..) |sock, idx| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                slog.info("Found socket index for node {s}, connector {s}", .{ node.desc.entry_point, name });
                return idx;
            }
        }
    }
    return null;
}
