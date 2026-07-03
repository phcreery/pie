const std = @import("std");

// APP
pub const app = @import("gui/app.zig");

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
