const std = @import("std");

pub fn main() !void {
    // std.log.info("Starting Integration tests", .{});
}

test {
    // std.testing.log_level = .debug;
    // GPU
    // _ = @import("engine/gpu_simple.zig");
    // _ = @import("engine/gpu_db.zig");
    // _ = @import("engine/gpu_param.zig");

    // PIPELINE
    // _ = @import("engine/pipeline.zig");

    // MISC
    _ = @import("fullsize/DSC_6765.zig");
    // _ = @import("misc/zpool.zig");
    // _ = @import("misc/musubi.zig");
    // _ = @import("misc/zig-graph.zig");
}
