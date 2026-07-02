const std = @import("std");

// APP
pub const app = @import("gui/app.zig");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main(init: std.process.Init) !void {
    app.run(init);
}
