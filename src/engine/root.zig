pub const std = @import("std");

pub const ROI = @import("ROI.zig");
pub const Module = @import("Module.zig");
pub const Node = @import("Node.zig");
pub const gpu = @import("gpu.zig");
pub const pipeline = @import("pipeline.zig");
pub const api = @import("modules/api.zig");
pub const modules = @import("modules/modules.zig");

pub const graph = @import("zig-graph/graph.zig");
pub const HashMapPool = @import("pool_hash_map.zig").HashMapPool;

pub const GPU = gpu.GPU;
pub const Buffer = gpu.Buffer;
pub const Encoder = gpu.Encoder;
pub const ComputePipeline = gpu.ComputePipeline;
pub const Texture = gpu.Texture;
pub const TextureFormat = gpu.TextureFormat;

pub const Pipeline = pipeline.Pipeline;

// pub const PIE = struct {
//     allocator: std.mem.Allocator,
//     io: std.Io,
//     gpu: *gpu.GPU,

//     // TODO: multiple pipeline suppot
//     // currently just one pipeline
//     pipeline: *pipeline.Pipeline,
// };

// test {
//     // _ = @import("engine/gpu.zig");
//     // _ = @import("engine/gpu_data.zig");
//     // _ = @import("engine/modules/shared/CFA.zig");
//     // _ = @import("engine/modules/i-raw/i-raw.zig");
//     // _ = @import("engine/zig-graph/graph.zig");
//     // _ = @import("engine/zig-graph/print.zig");
//     // _ = @import("engine/pool_hash_map.zig");
//     _ = @import("engine/Param.zig");
//     // _ = @import("engine/ImgParam.zig");
// }
