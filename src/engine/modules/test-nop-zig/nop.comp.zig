// zig build-obj -freference-trace=6 ./src/engine/modules/test-nop-zig/nop.comp.zig -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2 -fno-llvm -femit-bin='./src/engine/modules/test-nop-zig/nop.comp.spv'
// spirv-link --target-env=spv1.1 ./src/engine/modules/test-nop-zig/nop.comp.spv -o ./src/engine/modules/test-nop-zig/nopopt.comp.spv

const std = @import("std");
const spirv = std.spirv;

pub const InputImage = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = f32 },
    .format = .unknown,
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

const input_image = @extern(*addrspace(.constant) const InputImage, .{
    .name = "input",
    .decoration = .{ .descriptor = .{ .set = 1, .binding = 0 } },
});
const output_image = @extern(*addrspace(.constant) const OutputImage, .{
    .name = "output",
    .decoration = .{ .descriptor = .{ .set = 1, .binding = 1 } },
});

pub const Vec4f32 = @Vector(4, f32);
pub const Vec2u32 = @Vector(2, u32);

export fn main() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void {
    const coord = @as(Vec2u32, .{ 0, 0 });
    const lod: i32 = 0;
    asm volatile (
        \\%in = OpLoad %InputImage %input_image
        \\%pix = OpImageFetch %Vec4f32 %in %coord Lod %lod
        \\%out = OpLoad %OutputImage %output_image
        \\      OpImageWrite %out %coord %pix
        :
        : [InputImage] "t" (InputImage),
          [input_image] "" (input_image),
          [Vec4f32] "t" (Vec4f32),
          [OutputImage] "t" (OutputImage),
          [output_image] "" (output_image),
          [coord] "" (coord),
          [lod] "" (lod),
    );
}
