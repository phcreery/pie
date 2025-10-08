const std = @import("std");

const libraw = @import("libraw");

pub fn main() !void {
    std.debug.print("Hello, world!\n", .{});
    std.debug.print("LibRaw version: {s}\n", .{libraw.libraw_version()});
}
