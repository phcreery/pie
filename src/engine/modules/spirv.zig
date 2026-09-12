const std = @import("std");
pub const spirv = std.spirv;

pub const call_conv: std.lang.CallingConvention = .{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } };

pub extern const global_invocation_id: @Vector(3, u32) addrspace(.input);

pub const Vec4f32 = @Vector(4, f32);
pub const Vec2u32 = @Vector(2, u32);

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

// pub fn Image(comptime T: type) type {
//     return @SpirvType(.{ .image = .{
//         .usage = .{ .storage = f32 },
//         .format = .rgba16f,
//         .dim = .@"2d",
//         .depth = .not_depth,
//         .arrayed = false,
//         .multisampled = false,
//         .access = .unknown,
//     } });
// };

// pub fn imageFromDesc(name: []const u8) *addrspace(.constant) const InputImage {
//     return @extern(*addrspace(.constant) const InputImage, .{
//         .name = name,
//         .decoration = .{ .descriptor = .{ .set = 1, .binding = 0 } },
//     });
// }

/// Fetch a single texel from a *sampled* image at integer coordinates.
/// std.spirv has no counterpart to imageWrite() for reads: reading without a
/// sampler is OpImageFetch (OpImageRead is only valid for storage images, and
/// wgpu hands us the input as a sampled texture), so we wrap it by hand in the
/// same style as std.spirv.imageWrite.
pub inline fn imageFetch(image: *addrspace(.constant) const InputImage, coordinate: Vec2u32) Vec4f32 {
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
pub inline fn imageWrite(image: *addrspace(.constant) const OutputImage, coordinate: Vec2u32, texel: Vec4f32) void {
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
