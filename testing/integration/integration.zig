const std = @import("std");
// const pie = @import("pie");

pub fn main() !void {
    // std.log.info("Starting Integration tests", .{});
}

test {
    // GPU
    _ = @import("engine/gpu_simple.zig");
    _ = @import("engine/gpu_db.zig");

    // PIPELINE
    // _ = @import("engine/pipeline.zig");

    // _ = @import("fullsize/DSC_6765.zig");

    // MISC
    // _ = @import("misc/zpool.zig");
    // _ = @import("misc/musubi.zig");
    // _ = @import("misc/zig-graph.zig");
}
