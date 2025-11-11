const std = @import("std");

// APP
const app = @import("ui/app.zig");

// EXPORTS
pub const engine = @import("engine/engine.zig");
pub const iraw = @import("engine/modules/i-raw/i-raw.zig");

// pub const musubi = @import("musubi/musubi.zig");
// pub const zig_graph = @import("engine/zig-graph/graph.zig");

// SHORTCUTS
pub const gpu = engine.gpu;
pub const GPU = engine.gpu.GPU;
pub const Texture = engine.gpu.Texture;
// pub const GPUAllocator = engine.gpu.GPUAllocator;
pub const pipeline = engine.pipeline;
pub const Pipeline = engine.pipeline.Pipeline;
pub const Module = engine.pipeline.Module;

pub fn main() !void {
    app.run();
}

test {
    // _ = @import("engine/gpu.zig");
    // _ = @import("engine/modules/shared/CFA.zig");
    // _ = @import("engine/modules/i-raw/i-raw.zig");
    _ = @import("engine/zig-graph/graph.zig");
    // _ = @import("pool.zig");

    // _ = @import("musubi/musubi.zig");
}
