const std = @import("std");
const api = @import("modules/api.zig");
const pipeline = @import("pipeline.zig");
const Param = @import("Param.zig");
const slog = std.log.scoped(.mod);

desc: api.ModuleDesc,
enabled: bool,

// for the buffer that will live on the gpu
// the handle is needed for gpu pipeline bindings
param_handle: ?pipeline.ParamBufferHandle = null,

// the offset of this module's params in the staging/upload buffer
// the slice is used for writing params to the staging buffer before uploading to gpu
// mapped_param_buf_slice: ?[]u8 = null,
mapped_param_slice_ptr: ?*anyopaque = null,
// the offset and size is needed for enqueueBufToBuf
param_offset: ?usize = null,
param_size: ?usize = null,

const Self = @This();

pub fn init(desc: api.ModuleDesc) !Self {
    return Self{
        .desc = desc,
        .enabled = true,
    };
}

// HELPER FUNCTIONS

pub fn getSocketIndex(mod: *const Self, name: []const u8) ?usize {
    for (mod.desc.sockets, 0..) |sock, idx| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return idx;
            }
        }
    }
    return null;
}

pub fn getSocketPtr(mod: *Self, name: []const u8) ?*api.SocketDesc {
    const idx = mod.getSocketIndex(name) orelse return null;
    if (mod.desc.sockets[idx]) |*sock| {
        return sock;
    }
    return null;
}

pub fn getParamIndex(mod: *const Self, name: []const u8) ?usize {
    if (mod.desc.params) |params| {
        for (params, 0..) |param, idx| {
            if (param) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    return idx;
                }
            }
        }
    }
    return null;
}

pub fn getParamPtr(mod: *Self, name: []const u8) ?*Param {
    const idx = mod.getParamIndex(name) orelse return null;
    if (mod.desc.params) |*params| {
        if (params[idx]) |*param| {
            return param;
        }
    }
    return null;
}
