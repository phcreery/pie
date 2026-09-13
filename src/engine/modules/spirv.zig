const std = @import("std");
pub const spirv = std.spirv;

pub const call_conv: std.lang.CallingConvention = .{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } };

pub extern const global_invocation_id: @Vector(3, u32) addrspace(.input);

pub const Vec4f32 = @Vector(4, f32);
pub const Vec2u32 = @Vector(2, u32);

// pub const InputImage = @SpirvType(.{ .image = .{
//     .usage = .{ .sampled = f32 },
//     .format = .rgba16f,
//     .dim = .@"2d",
//     .depth = .not_depth,
//     .arrayed = false,
//     .multisampled = false,
//     .access = .unknown,
// } });
pub const OutputImage = @SpirvType(.{ .image = .{
    .usage = .{ .storage = f32 },
    .format = .rgba16f,
    .dim = .@"2d",
    .depth = .not_depth,
    .arrayed = false,
    .multisampled = false,
    .access = .unknown,
} });

pub const SocketType = enum {
    read,
    write,
    source,
    sink,
};

// mirrors gpu.TextureFormat
pub const TextureFormat = enum {
    rgba16float,
    rgba16uint,
    r8uint,
    r16uint,
    r16float,
    rggb32float,
    rggb16uint,

    pub fn toSpirvImageFormat(self: TextureFormat) std.lang.Type.Spirv.Image.Format {
        return switch (self) {
            .rgba16float => .rgba16f,
            .rgba16uint => .rgba16u,
            .r8uint => .unknown,
            .r16uint => .unknown,
            .r16float => .unknown,

            // special cases: bayer mosaic stored single-channel
            .rggb32float => .r32f,
            .rggb16uint => .unknown,
        };
    }

    pub fn toBaseType(self: TextureFormat) type {
        return switch (self) {
            .rgba16float => f16,
            .rgba16uint => u16,
            .r8uint => u8,
            .r16uint => u16,
            .r16float => f16,

            // special cases: bayer mosaic stored single-channel
            .rggb32float => f32,
            .rggb16uint => u16,
        };
    }
};

const SocketDescZon = struct {
    name: []const u8,
    type: SocketType,
    format: TextureFormat,

    pub fn toSpirvUsage(self: SocketDescZon) std.lang.Type.Spirv.Image.Usage {
        const T = self.format.toBaseType();
        return switch (self.type) {
            // .read => .{ .sampled = T },
            .read => .{ .sampled = f32 },
            .write => .{ .storage = T },
            .source, .sink => unreachable,
        };
    }
};

pub const ShaderLanguage = enum {
    wgsl,
    spirv,
    glsl,
};

const ShaderSourceFileName = union(ShaderLanguage) {
    wgsl: []const u8,
    spirv: []const u8,
    glsl: []const u8,
};

const NodeDescZon = struct {
    shader: ShaderSourceFileName,
    name: []const u8,
    sockets: []const SocketDescZon,
};

pub fn Image(comptime desc: NodeDescZon, comptime name: []const u8) type {
    _ = name;
    const socket: SocketDescZon = desc.sockets[0];
    return @SpirvType(.{ .image = .{
        .usage = socket.toSpirvUsage(),
        .format = socket.format.toSpirvImageFormat(),
        .dim = .@"2d",
        .depth = .not_depth,
        .arrayed = false,
        .multisampled = false,
        .access = .unknown,
    } });
    // return struct {};
}

// pub fn imageFromDesc(name: []const u8) *addrspace(.constant) const InputImage {
//     return @extern(*addrspace(.constant) const InputImage, .{
//         .name = name,
//         .decoration = .{ .descriptor = .{ .set = 1, .binding = 0 } },
//     });
// }

// pub const output_image = @extern(*addrspace(.constant) const OutputImage, .{
//     .name = "output",
//     .decoration = .{ .descriptor = .{ .set = 1, .binding = 1 } },
// });

pub fn imageFromZon(comptime T: type, comptime zon: NodeDescZon, name: []const u8) *addrspace(.constant) const T {
    // for testing, just get first socekt
    const socket = zon.sockets[0];
    _ = socket;
    return @extern(*addrspace(.constant) const T, .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = 1, .binding = 0 } },
    });
}

/// Fetch a single texel from a *sampled* image at integer coordinates.
/// std.spirv has no counterpart to imageWrite() for reads: reading without a
/// sampler is OpImageFetch (OpImageRead is only valid for storage images, and
/// wgpu hands us the input as a sampled texture), so we wrap it by hand in the
/// same style as std.spirv.imageWrite.
pub inline fn imageFetch(comptime T: type, image: T, coordinate: Vec2u32) Vec4f32 {
    const lod: i32 = 0; // required image operand for non-multisampled fetches
    return asm volatile (
        \\%in  = OpLoad %T %image
        \\%ret = OpImageFetch %Vec4f32 %in %coordinate Lod %lod
        : [ret] "" (-> Vec4f32),
        : [T] "t" (T),
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
