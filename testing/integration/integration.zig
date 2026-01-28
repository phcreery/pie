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
    // _ = @import("engine/gpu_fullsize_DSC_6765.zig");

    // PIPELINE
    // _ = @import("engine/pipe_simple.zig");
    _ = @import("engine/pipe_fullsize.zig");

    // MISC
    // _ = @import("misc/zpool.zig");
    // _ = @import("misc/musubi.zig");
    // _ = @import("misc/zig-graph.zig");
}
