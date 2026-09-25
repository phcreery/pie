const std = @import("std");
const api = @import("modules/api.zig");
const pipeline = @import("pipeline.zig");
const Param = @import("Param.zig");
const ImgParam = @import("ImgParam.zig");
const Socket = api.Socket;
const slog = std.log.scoped(.mod);

id: []const u8,
name: []const u8,
type: api.ModuleType,
enabled: bool,

dirty: bool = false,

/// Live sockets, copied from `desc.sockets` at registration. All runtime
/// socket state (roi, private members) lives here; the desc is never mutated.
sockets: [api.MAX_SOCKETS]?Socket = @splat(null),

/// The declared params, created from `desc.params` at registration. Each
/// `Param` carries its own `ParamDesc`, so this is the single source of truth
/// for param metadata; the module's `initParams` hook fills in the values.
params: [api.MAX_PARAMS_PER_MODULE]?Param = @splat(null),

/// UI hints, copied from `desc.params_ui`; index-aligned with `params`.
params_ui: [api.MAX_PARAMS_PER_MODULE]?api.ParamUI = @splat(null),

/// Module-private data (e.g. a source module's loaded image). Owned by the
/// module implementation.
data: ?*anyopaque = null,

/// for the buffer that will live on the gpu
/// the handle is needed for gpu pipeline bindings
param_handle: ?pipeline.ParamBufferHandle = null,
/// the offset of this module's params in the staging/upload buffer
/// the slice is used for writing params to the staging buffer before uploading to gpu
param_mapped_slice_ptr: ?*anyopaque = null,
/// the offset and size is needed for enqueueBufToBuf
param_offset: ?usize = null,
param_size: ?usize = null,

img_param: ?ImgParam.ImgParams = null,
img_param_handle: ?pipeline.ParamBufferHandle = null,
img_param_mapped_slice_ptr: ?*anyopaque = null,
img_param_offset: ?usize = null,
img_param_size: ?usize = null,

// module hooks, copied from the desc
// https://github.com/hanatos/vkdt/blob/1921eabfa2c87b90042dee676d5d3e34d8cbd5e1/src/pipe/global.c#L106
initParams: ?*const fn (pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle) anyerror!void = null,
init: ?*const fn (allocator: std.mem.Allocator, io: std.Io, pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle) anyerror!void = null,
deinit: ?*const fn (allocator: std.mem.Allocator, pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle) void = null,
modifyOut: ?*const fn (pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle) anyerror!void = null,
createNodes: ?*const fn (pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle) anyerror!void = null,
readSource: ?*const fn (pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle, mapped: *anyopaque) anyerror!void = null,
writeSink: ?*const fn (allocator: std.mem.Allocator, io: std.Io, pipe: *pipeline.Pipeline, mod: pipeline.ModuleHandle, mapped: *anyopaque) anyerror!void = null,

const Self = @This();

/// Build a live module from its (comptime) descriptor: the descriptor's
/// metadata, interface and hooks are copied into fixed-length runtime arrays.
pub fn initFromDesc(allocator: std.mem.Allocator, id: []const u8, desc: api.ModuleDesc) !Self {
    var self = Self{
        .id = id,
        .name = desc.name,
        .type = desc.type,
        .enabled = true,

        // copy the declared metadata and interface into fixed-length runtime arrays
        .data = null,
        .initParams = desc.initParams,
        .init = desc.init,
        .deinit = desc.deinit,
        .modifyOut = desc.modifyOut,
        .createNodes = desc.createNodes,
        .readSource = desc.readSource,
        .writeSink = desc.writeSink,
    };
    for (desc.sockets, 0..) |sock, i| {
        self.sockets[i] = Socket.fromDesc(sock);
    }
    errdefer for (&self.params) |*maybe_param| {
        if (maybe_param.*) |*param| param.deinit(allocator);
    };
    for (desc.params, 0..) |param_desc, i| {
        self.params[i] = try Param.fromDesc(allocator, param_desc);
    }
    // params_ui is a prefix list: entry i describes param i
    for (desc.params_ui, 0..) |ui, i| {
        self.params_ui[i] = ui;
    }
    return self;
}

// HELPER FUNCTIONS

pub fn getSocketIndex(mod: *const Self, name: []const u8) !usize {
    for (mod.sockets, 0..) |sock, idx| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return idx;
            }
        }
    }
    return error.ModuleSocketNotFound;
}

pub fn getSocketPtr(mod: *Self, name: []const u8) !*Socket {
    const idx = try mod.getSocketIndex(name);
    if (mod.sockets[idx]) |*sock| {
        return sock;
    }
    return error.ModuleSocketNotFound;
}

pub fn getParamIndex(mod: *const Self, name: []const u8) !usize {
    for (mod.params, 0..) |maybe_param, idx| {
        if (maybe_param) |param| {
            if (std.mem.eql(u8, param.desc.name, name)) {
                return idx;
            }
        }
    }
    return error.ModuleParamNotFound;
}

pub fn getParamPtr(mod: *Self, name: []const u8) !*Param {
    const idx = try mod.getParamIndex(name);
    if (mod.params[idx]) |*param| {
        return param;
    }
    return error.ModuleParamNotFound;
}

pub fn params_len(mod: *Self) usize {
    var count: usize = 0;
    for (mod.params) |maybe_param| {
        if (maybe_param != null) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}
