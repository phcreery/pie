const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.node);

desc: api.NodeDesc,
mod: pipeline.ModuleHandle,
shader: ?gpu.ShaderPipe = null,
bindings: ?gpu.Bindings = null,

const Self = @This();

pub fn init(
    pipe: *pipeline.Pipeline,
    mod: pipeline.ModuleHandle,
    desc: api.NodeDesc,
) !Self {
    var shader: ?gpu.ShaderPipe = null;
    if (desc.type == .compute) {
        // CREATE DESCRIPTIONS
        // all sockets are on group 0
        var layout_group_0_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
        for (desc.sockets, 0..) |socket, binding_number| {
            if (socket) |sock| {
                // prepare shader pipe connections
                layout_group_0_binding[binding_number] = gpu.BindGroupLayoutEntry{
                    .texture = .{
                        .access = sock.type.toShaderPipeBindGroupLayoutEntryAccess(),
                        .format = sock.format,
                    },
                };
                slog.debug("Added bind group layout entry for binding {d}", .{binding_number});
            }
        }

        // params are on group 1
        var layout_group_1_binding: [gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
        // var bind_group_1_binds: [gpu.MAX_BINDINGS]?gpu.BindGroupEntry = @splat(null);
        const m = pipe.module_pool.getPtr(mod) catch unreachable;
        if (m.*.param_handle) |_| {
            layout_group_1_binding[0] = .{ .buffer = .{} };
        }

        // CREATE SHADER PIPE AND BINDINGS
        slog.debug("Creating shader for node with entry point: {s}", .{desc.entry_point});
        var layout_group: [gpu.MAX_BIND_GROUPS]?[gpu.MAX_BINDINGS]?gpu.BindGroupLayoutEntry = @splat(null);
        layout_group[0] = layout_group_0_binding;
        layout_group[1] = layout_group_1_binding;
        const gpu_inst = pipe.gpu orelse return error.PipelineGPUNotInitialized;
        shader = try gpu.ShaderPipe.init(
            gpu_inst,
            desc.shader_code,
            desc.entry_point,
            layout_group,
        );
    }

    return Self{
        .desc = desc,
        .mod = mod,
        .shader = shader,
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

pub fn getSocketIndex(node: *const Self, name: []const u8) ?usize {
    for (node.desc.sockets, 0..) |sock, idx| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return idx;
            }
        }
    }
    return null;
}
pub fn getSocketPtr(node: *Self, name: []const u8) ?*api.SocketDesc {
    const idx = node.getSocketIndex(name) orelse return null;
    if (node.desc.sockets[idx]) |*sock| {
        return sock;
    }
    return null;
}
