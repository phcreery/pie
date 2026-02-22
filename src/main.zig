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
    // _ = @import("engine/gpu_data.zig");
    // _ = @import("engine/modules/shared/CFA.zig");
    // _ = @import("engine/modules/i-raw/i-raw.zig");
    // _ = @import("engine/zig-graph/graph.zig");
    // _ = @import("engine/zig-graph/print.zig");
    // _ = @import("engine/pool_hash_map.zig");
    _ = @import("engine/Param.zig");
    // _ = @import("engine/ImgParam.zig");
}

// test "anon struct param" {
//     const params = &.{
//         .{ .name = "float", .value = @as(f32, 3.14) },
//         .{ .name = "vec3", .value = [3]f32{ 1.0, 2.0, 3.0 } },
//         .{ .name = "mat3x3", .value = [3][3]f32{
//             .{ 1.0, 0.0, 0.0 },
//             .{ 0.0, 1.0, 0.0 },
//             .{ 0.0, 0.0, 1.0 },
//         } },
//     };

//     const Desc = struct {
//         name: []const u8,
//         params: *anyopaque,
//     };

//     const s: Desc = .{
//         .name = "a",
//         .params = @ptrCast(@constCast(params)),
//     };
//     std.debug.print("{any}", .{s});
// }
