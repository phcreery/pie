const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {}

comptime {
    if (builtin.is_test) {
        // GPU
        _ = @import("engine/gpu_r16.zig");
        _ = @import("engine/gpu_simple.zig");
        _ = @import("engine/gpu_db.zig");
        _ = @import("engine/gpu_param.zig");
        _ = @import("engine/gpu_fullsize_DSC_6765.zig");

        // PIPELINE
        _ = @import("engine/pipe_simple.zig");
        _ = @import("engine/pipe_history.zig");
        _ = @import("engine/pipe_serdes.zig");
        _ = @import("engine/pipe_dirty.zig");
        _ = @import("engine/pipe_fullsize.zig");
        _ = @import("engine/pipe_png.zig");
        _ = @import("engine/pipe_graphs.zig");

        // TARGETS
        _ = @import("targets/targets.zig");
    }
}
