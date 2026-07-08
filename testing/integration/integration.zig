const std = @import("std");
const builtin = @import("builtin");

// pub const std_options = std.Options{
//     // .log_scope_levels = &[_]std.log.ScopeLevel{
//     //     // .{ .scope = .websocket, .level = .debug },
//     //     .{ .scope = .gpu, .level = .debug },
//     // },
//     // .logFn = customLogFn,
//     .log_level = .debug,
// };

pub fn main() !void {}

comptime {
    if (builtin.is_test) {

        // std.testing.log_level = .debug;
        // GPU
        // _ = @import("engine/gpu_simple.zig");
        // _ = @import("engine/gpu_db.zig");
        // _ = @import("engine/gpu_param.zig");
        // _ = @import("engine/gpu_fullsize_DSC_6765.zig");

        // PIPELINE
        // _ = @import("engine/pipe_simple.zig");
        // _ = @import("engine/pipe_fullsize.zig");

        // TARGETS
        _ = @import("targets/targets.zig");

        // MISC
        // _ = @import("misc/zpool.zig");
        // _ = @import("misc/musubi.zig");
        // _ = @import("misc/zig-graph.zig");
    }
}
