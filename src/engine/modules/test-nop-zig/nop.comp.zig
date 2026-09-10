// zig build-obj -freference-trace=6 ./src/engine/modules/test-nop-zig/nop.comp.zig -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2 -fno-llvm -femit-bin='./src/engine/modules/test-nop-zig/nop.comp.spv'
// spirv-link --target-env=spv1.1 ./src/engine/modules/test-nop-zig/nop.comp.spv -o ./src/engine/modules/test-nop-zig/nopopt.comp.spv
// diff -u --color <(spirv-dis src/engine/modules/test-nop-zig/nop.comp.spv) <(spirv-dis src/engine/modules/test-nop-zig/nopopt.comp.spv)

const std = @import("std");
const spirv = std.spirv;

pub const InputImage = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = f32 },
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

/// Fetch a single texel from a *sampled* image at integer coordinates.
/// std.spirv has no counterpart to imageWrite() for reads: reading without a
/// sampler is OpImageFetch (OpImageRead is only valid for storage images, and
/// wgpu hands us the input as a sampled texture), so we wrap it by hand in the
/// same style as std.spirv.imageWrite.
inline fn imageFetch(image: *addrspace(.constant) const InputImage, coordinate: Vec2u32) Vec4f32 {
    const lod: i32 = 0; // required image operand for non-multisampled fetches
    return asm volatile (
        \\%in  = OpLoad %InputImage %image
        \\%ret = OpImageFetch %Vec4f32 %in %coordinate Lod %lod
        : [ret] "" (-> Vec4f32),
        : [InputImage] "t" (InputImage),
          [image] "" (image),
          [Vec4f32] "t" (Vec4f32),
          [coordinate] "" (coordinate),
          [lod] "" (lod),
    );
}

/// Write a texel to a *storage* image. Equivalent of std.spirv.imageWrite,
/// but as a local `inline fn` for two reasons on the current Zig master:
///  - naga (wgpu's SPIR-V front-end) rejects OpImageWrite when the image is
///    anything other than a global variable, so the wrapper must be inlined;
///    the SPIR-V backend never inlines plain calls and miscompiles
///    @call(.always_inline) on 3-parameter functions.
///  - std.spirv.imageWrite is a regular (non-inline) function.
inline fn imageWrite(image: *addrspace(.constant) const OutputImage, coordinate: Vec2u32, texel: Vec4f32) void {
    asm volatile (
        \\%out = OpLoad %OutputImage %image
        \\      OpImageWrite %out %coordinate %texel
        :
        : [OutputImage] "t" (OutputImage),
          [image] "" (image),
          [coordinate] "" (coordinate),
          [texel] "" (texel),
    );
}

export fn main() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void {
    const coord = @as(Vec2u32, .{ std.spirv.global_invocation_id[0], std.spirv.global_invocation_id[1] });
    const pix = imageFetch(input_image, coord);
    imageWrite(output_image, coord, pix);
}
