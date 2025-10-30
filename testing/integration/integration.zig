const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

pub fn main() !void {
    std.log.info("Starting Integration tests", .{});
}

test {
    // _ = @import("engine/gpu.zig");
    // _ = @import("fullsize/DSC_6765.zig");
    _ = @import("engine/pipeline.zig");
}
