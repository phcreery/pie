// zig build-obj ./src/engine/modules/test-nop-zig/nop.comp.zig -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2 -fno-llvm -femit-bin='./src/engine/modules/test-nop-zig/nop.comp.spv'

// using zig 0.16/0.17-master syntax
// see https://codeberg.org/7Games/zig-sdl3/src/commit/efe71e6e05324535dd46e06fd0b3fb557d5fdf14/gpu_examples/shaders/zig

// const spirv = @import("spirv.zig");
const std = @import("std");
const spirv = std.spirv;

// std.spirv

// const options: std.lang.Type.Spirv = .{};

pub const InputImage = @SpirvType(.{ .image = .{
    .usage = .{ .storage = f32 },
    .format = .rgba16f,
    .dim = .@"2d",
    .depth = .not_depth,
    .arrayed = false,
    .multisampled = false,
    .access = .unknown,
} });
pub const OutputImage = @SpirvType(.{ .image = .{
    .usage = .{ .storage = f32 },
    .format = .rgba16f,
    .dim = .@"2d",
    .depth = .not_depth,
    .arrayed = false,
    .multisampled = false,
    .access = .unknown,
} });

const input_image = @extern(*addrspace(.input) const InputImage, .{
    .name = "image",
    .decoration = .{ .descriptor = .{ .set = 1, .binding = 0 } },
});
const output_image = @extern(*addrspace(.output) const OutputImage, .{
    .name = "image",
    .decoration = .{ .descriptor = .{ .set = 1, .binding = 1 } },
});

export fn main() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void {
    // TODO!!!
    spirv.imageWrite(
        output_image,
        u32,
        .{ std.spirv.global_invocation_id[0], std.spirv.global_invocation_id[1] },
        .{ 1, 1, 0, 1 },
    );
}
