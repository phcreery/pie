const std = @import("std");

// APP
pub const app = @import("ui/app.zig");
pub const cli = @import("cli/cli.zig");

// EXPORTS
pub const engine = @import("engine/engine.zig");

// SHORTCUTS
pub const gpu = engine.gpu;
pub const GPU = engine.gpu.GPU;
pub const Texture = engine.gpu.Texture;
pub const Buffer = engine.gpu.Buffer;
pub const pipeline = engine.pipeline;
pub const Pipeline = engine.pipeline.Pipeline;
pub const Module = engine.pipeline.Module;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main() !void {
    app.run();
}

test {
    // _ = @import("engine/gpu.zig");
    // _ = @import("engine/modules/shared/CFA.zig");
    // _ = @import("engine/modules/i-raw/i-raw.zig");
    // _ = @import("engine/zig-graph/graph.zig");
    // _ = @import("engine/zig-graph/print.zig");
    // _ = @import("engine/pool_hash_map.zig");
    _ = @import("engine/Param.zig");
}
