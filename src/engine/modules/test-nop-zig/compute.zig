// zig build-obj .\src\engine\modules\test-nop-zig\compute.zig -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2 -fno-llvm -femit-bin='.\src\engine\modules\test-nop-zig\compute.spv'

// const shader_code: []const u8 =
//     \\enable f16;
//     \\@group(1) @binding(0) var input  : texture_2d<f32>;
//     \\@group(1) @binding(1) var output : texture_storage_2d<rgba16float, write>;
//     \\@compute @workgroup_size(8, 8, 1)
//     \\fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
//     \\    let coords = vec2<i32>(global_id.xy);
//     \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
//     \\    textureStore(output, coords, pixel);
//     \\}
// ;
// In GLSL, this input must be a texture-only binding, not a combined sampler.
// The engine binds socket 0 as a texture view with no sampler object.
// const shader_code: []const u8 =
//     \\#version 450
//     \\layout(set = 1, binding = 0) uniform texture2D input;
//     \\layout(set = 1, binding = 1, rgba16f) uniform writeonly image2D output;
//     \\layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
//     \\void main() {
//     \\    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
//     \\    vec4 pixel = texelFetch(input, coords, 0);
//     \\    imageStore(output, coords, pixel);
//     \\}
// ;

// ====================
// zig 0.16

// const gpu = @import("std").gpu;

// // const N: u32 = 16;
// // const in_buf = gpu.runtimeArray(f32, 0, 0, "in_buf");
// // const out_buf = gpu.runtimeArray(f32, 0, 1, "out_buf");

// const input = gpu.extern(*addrspace(.input) f32, .{ .name = "input" });

// export fn main() callconv(.spirv_kernel) void {
//     gpu.executionMode(main, .{ .local_size = .{ .x = 8, .y = 8, .z = 8 } });

//     gpu.binding(&ubo, 0, 0);
// }

// ====================
// using zig 0.16
// see https://codeberg.org/shahwali/knots/src/branch/main/src/gpu/backend/vulkan/shaders (zig 0.17.0-dev.269+ebff43698)

// const Vec4f = @import("common.zig").Vec4f;
// const Vec2f = @import("common.zig").Vec2f;
// // const uniform = @import("common.zig").uniform;
// const input = @import("common.zig").input;
// const output = @import("common.zig").output;

// const in = input(Vec4f, "input", .{ .location = 0 });

// const out = output(Vec4f, "output", .{ .location = 0 });

// export fn main() callconv(.spirv_kernel) void {
//     // gpu.executionMode(main, .{ .local_size = .{ .x = 8, .y = 8, .z = 8 } });
//     out.* = in.*;
// }

// ====================
// using zig 0.16/0.17-master syntax
// see https://codeberg.org/7Games/zig-sdl3/src/commit/efe71e6e05324535dd46e06fd0b3fb557d5fdf14/gpu_examples/shaders/zig

const spirv = @import("spirv.zig");
const std = @import("std");

// std.spirv

// const options: std.lang.Type.Spirv = .{};

pub const InputImage = @SpirvType(.{ .image = .{
    .usage = .{ .storage = {} },
    .format = .rgba16f,
    .dim = .@"2d",
    .depth = .not_depth,
    .arrayed = false,
    .multisampled = false,
    .access = .unknown,
} });
pub const OutputImage = @SpirvType(.{ .image = .{
    .usage = .{ .storage = {} },
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
    spirv.imageWriteUint(
        output_image,
        .{ std.spirv.global_invocation_id[0], std.spirv.global_invocation_id[1] },
        .{ 1, 1, 0, 1 },
        .{},
    );
}
