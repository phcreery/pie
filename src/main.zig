const std = @import("std");
const builtin = @import("builtin");

// APP
pub const app = @import("app/app.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .gpu, .level = .info },
        .{ .scope = .pipe, .level = .info },
        .{ .scope = .suballocator, .level = .info },
        .{ .scope = .DebugAllocator, .level = .warn },
        // .logFn = customLogFn,
    },
};

pub fn main(init: std.process.Init) !void {
    try app.run(init);
}

comptime {
    if (builtin.is_test) {
        // std.testing.refAllDecls(@This());
        // _ = @import("foo.zig");
    }
}
