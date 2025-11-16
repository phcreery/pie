const std = @import("std");
const api = @import("api.zig");
const slog = std.log.scoped(.mod);

desc: api.ModuleDesc,
enabled: bool,

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
                slog.info("Found socket for module {s}, connector {s}", .{ mod.desc.name, name });
                return s;
            }
        }
    }
    return null;
}
