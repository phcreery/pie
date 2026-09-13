const std = @import("std");
const mt = @import("mirrored_types.zig");
pub const spirv = std.spirv; // TODO: remove this line
pub const NodeDescZon = mt.NodeDescZon;

pub const call_conv: std.lang.CallingConvention = .{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } };

pub extern const global_invocation_id: @Vector(3, u32) addrspace(.input);

pub const Vec4f32 = @Vector(4, f32);
pub const Vec2u32 = @Vector(2, u32);

fn getSocketIdx(comptime desc: mt.NodeDescZon, comptime name: []const u8) usize {
    for (desc.sockets, 0..) |socket, i| {
        if (std.mem.eql(u8, socket.name, name)) {
            return i;
        }
    }
    unreachable;
}

pub fn Image(comptime desc: mt.NodeDescZon, comptime name: []const u8) type {
    const socket = desc.sockets[getSocketIdx(desc, name)];
    return *addrspace(.constant) const @SpirvType(.{ .image = .{
        .usage = socket.toSpirvUsage(),
        .format = socket.format.toSpirvImageFormat(),
        .dim = .@"2d",
        .depth = .not_depth,
        .arrayed = false,
        .multisampled = false,
        .access = .unknown,
    } });
}

pub fn imageFromZon(comptime zon: mt.NodeDescZon, comptime name: []const u8) Image(zon, name) {
    const socket_idx = getSocketIdx(zon, name);
    return @extern(Image(zon, name), .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = 1, .binding = socket_idx } },
    });
}

/// Fetch a single texel from a *sampled* image at integer coordinates.
/// std.spirv has no counterpart to imageWrite() for reads: reading without a
/// sampler is OpImageFetch (OpImageRead is only valid for storage images, and
/// wgpu hands us the input as a sampled texture), so we wrap it by hand in the
/// same style as std.spirv.imageWrite.
/// image must be of type `Image`
pub inline fn imageFetch(image: anytype, coordinate: Vec2u32) Vec4f32 {
    const InputImage = @TypeOf(image);
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
/// image must be of type `Image`
pub inline fn imageWrite(image: anytype, coordinate: Vec2u32, texel: Vec4f32) void {
    const OutputImage = @TypeOf(image);
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
