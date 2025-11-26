const std = @import("std");
const api = @import("modules/api.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.mod);

desc: api.ModuleDesc,
enabled: bool,

// for the buffer that will live on the gpu
param_handle: ?pipeline.ParamBufferHandle = null,

// the offset of this module's params in the staging buffer
mapped_param_buf_slice: ?[]f32 = null,
param_offset: ?usize = null,
param_size: ?usize = null,

const Self = @This();

pub fn init(
    desc: api.ModuleDesc,
) !Self {
    return Self{
        .desc = desc,
        .enabled = true,
    };
}

// HELPER FUNCTIONS

pub fn getSocket(mod: *Self, name: []const u8) ?api.SocketDesc {
    const sockets = [_]?api.SocketDesc{
        mod.desc.input_socket,
        mod.desc.output_socket,
    };
    for (sockets) |sock| {
        if (sock) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                return s;
            }
        }
    }
    return null;
}
