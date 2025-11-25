const std = @import("std");
const api = @import("modules/api.zig");
const slog = std.log.scoped(.mod);

desc: api.ModuleDesc,
enabled: bool,
param_offset: usize,

const Self = @This();

pub fn init(
    desc: api.ModuleDesc,
) !Self {
    return Self{
        .desc = desc,
        .enabled = true,
        .param_offset = 0,
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
