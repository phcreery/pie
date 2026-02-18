const std = @import("std");
const api = @import("modules/api.zig");
const pipeline = @import("pipeline.zig");
const Param = @import("Param.zig");
const ImgParam = @import("ImgParam.zig");
const slog = std.log.scoped(.mod);

desc: api.ModuleDesc,
enabled: bool,

// params is in the desc field
// for the buffer that will live on the gpu
// the handle is needed for gpu pipeline bindings
param_handle: ?pipeline.ParamBufferHandle = null,
// the offset of this module's params in the staging/upload buffer
// the slice is used for writing params to the staging buffer before uploading to gpu
param_mapped_slice_ptr: ?*anyopaque = null,
// the offset and size is needed for enqueueBufToBuf
param_offset: ?usize = null,
param_size: ?usize = null,

img_param: ?ImgParam.ImgParams = null,
img_param_handle: ?pipeline.ParamBufferHandle = null,
img_param_mapped_slice_ptr: ?*anyopaque = null,
img_param_offset: ?usize = null,
img_param_size: ?usize = null,

const Self = @This();

pub fn init(desc: api.ModuleDesc) !Self {
    return Self{
        .desc = desc,
        .enabled = true,
    };
}

// HELPER FUNCTIONS

pub fn getSocketIndex(mod: *const Self, name: []const u8) !usize {
    for (mod.desc.sockets, 0..) |sock, idx| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return idx;
            }
        }
    }
    return error.ModuleSocketNotFound;
}

pub fn getSocketPtr(mod: *Self, name: []const u8) !*api.SocketDesc {
    const idx = try mod.getSocketIndex(name);
    if (mod.desc.sockets[idx]) |*sock| {
        return sock;
    }
    return error.ModuleSocketNotFound;
}

pub fn getParamIndex(mod: *const Self, name: []const u8) !usize {
    if (mod.desc.params) |params| {
        for (params, 0..) |param, idx| {
            if (param) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    return idx;
                }
            }
        }
    }
    return error.ModuleParamNotFound;
}

pub fn getParamPtr(mod: *Self, name: []const u8) !*Param {
    const idx = try mod.getParamIndex(name);
    if (mod.desc.params) |*params| {
        if (params[idx]) |*param| {
            return param;
        }
    }
    return error.ModuleParamNotFound;
}
