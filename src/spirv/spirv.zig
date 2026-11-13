//! Types and helpers available to shaders compiled by the Zig SPIR-V backend.
//! Shaders import this as `@import("shader")`.

const std = @import("std");
const types = @import("types");

pub const spirv = std.spirv; // TODO: remove this line
pub const NodeDesc = types.ModuleApi.NodeDesc;
pub const ModuleDesc = types.ModuleApi.ModuleDesc;

pub const math = @import("math");

pub const Vec4f32 = @Vector(4, f32);
pub const Vec2u32 = @Vector(2, u32);

pub const call_conv: std.lang.CallingConvention = .{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } };

pub extern const global_invocation_id: @Vector(3, u32) addrspace(.input);
pub fn coord() Vec2u32 {
    return @as(Vec2u32, .{ global_invocation_id[0], global_invocation_id[1] });
}

/// Comptime check that a shader params struct `T` has the same shape as the
/// GPU-visible params declared by `module_desc`: one field per param, in
/// declaration order, with matching names and element types.
///
/// `str` params are CPU-only and never enter the params buffer, so they are
/// skipped. This is what makes `getParams` safe: the engine packs params in
/// declaration order, so any field count/order/type drift silently reads the
/// wrong bytes.
pub fn assertParamsShape(comptime module_desc: ModuleDesc, comptime T: type) void {
    comptime {
        switch (@typeInfo(T)) {
            .@"struct" => {},
            else => @compileError("shader params type must be a struct, got '" ++ @typeName(T) ++ "'"),
        }

        const field_names = std.meta.fieldNames(T);
        const info = @typeInfo(T);
        const field_types = info.@"struct".field_types;

        var field_i: usize = 0;
        for (module_desc.params) |param| {
            if (param.typ == .str) continue;

            if (field_i >= field_types.len) {
                @compileError(@typeName(T) ++ " is missing a field for module param '" ++ param.name ++ "'");
            }
            const name = field_names[field_i];

            if (!std.mem.eql(u8, name, param.name)) {
                @compileError("shader params field '" ++ name ++ "' does not match module param '" ++ param.name ++ "'");
            }

            const expected: type = switch (param.typ) {
                .f32 => switch (param.len) {
                    1 => f32,
                    2 => [2]f32,
                    3 => [3]f32,
                    4 => [4]f32,
                    else => @compileError("unsupported f32 param length for '" ++ param.name ++ "'"),
                },
                .i32 => switch (param.len) {
                    1 => i32,
                    else => @compileError("unsupported i32 param length for '" ++ param.name ++ "'"),
                },
                .str => unreachable,
                .@"enum" => u32, // enums are represented as u32 on the CPU side
            };

            var actual = field_types[field_i];
            if (@typeInfo(actual) == .@"enum") {
                actual = u32;
            }
            if (actual != expected) {
                @compileError("shader params field '" ++ name ++ "' is '" ++ @typeName(actual) ++ "' but module param '" ++ param.name ++ "' is '" ++ @typeName(expected) ++ "'");
            }

            field_i += 1;
        }

        if (field_i != field_types.len) {
            @compileError(@typeName(T) ++ " has more fields than the GPU-visible module params");
        }
    }
}

pub fn getParams(comptime module_desc: ModuleDesc, T: type) *addrspace(.storage_buffer) T {
    assertParamsShape(module_desc, T);
    return @extern(*addrspace(.storage_buffer) T, .{
        .name = "params",
        .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
    });
}

/// `T` must be the std140 view of the CPU struct: `types.ImgParamsGpu`.
pub fn getImgParams(comptime module_desc: ModuleDesc, comptime T: type) *addrspace(.uniform) const T {
    comptime {
        if (T != @import("types").ImgParamsGpu) {
            @compileError("getImgParams expects types.ImgParamsGpu, got '" ++ @typeName(T) ++ "'");
        }
    }
    return @extern(*addrspace(.uniform) const T, .{
        .name = "img_params",
        .decoration = .{ .descriptor = .{ .set = 0, .binding = if (module_desc.params.len == 0) 0 else 1 } },
    });
}

fn getSocketIdx(comptime desc: NodeDesc, comptime name: []const u8) usize {
    for (desc.sockets, 0..) |socket, i| {
        if (std.mem.eql(u8, socket.name, name)) {
            return i;
        }
    }
    unreachable;
}

pub fn toSpirvUsage(socket: types.ModuleApi.SocketDesc) std.lang.Type.Spirv.Image.Usage {
    // const T = self.format.toBaseType();
    return switch (socket.type) {
        // .read => .{ .sampled = T },
        .read => .{ .sampled = f32 },
        // 'storage' field value must be a 32-bit int, 64-bit int or 32-bit float under the 'vulkan' os
        .write => .{ .storage = f32 },
        .source, .sink => unreachable,
    };
}

pub fn toSpirvImageFormat(texture_format: types.ModuleApi.TextureFormat) std.lang.Type.Spirv.Image.Format {
    return switch (texture_format) {
        .rgba16float => .rgba16f,
        .rgba16uint => .rgba16u,
        .r8uint => .unknown,
        .r16uint => .unknown,
        .r16float => .unknown,

        // special cases: bayer mosaic stored single-channel
        .rggb32float => .r32f,
        .rggb16uint => .unknown,
        .any => .unknown,
    };
}

pub fn toBaseType(texture_format: types.ModuleApi.TextureFormat) type {
    return switch (texture_format) {
        .rgba16float => f16,
        .rgba16uint => u16,
        .r8uint => u8,
        .r16uint => u16,
        .r16float => f16,

        // special cases: bayer mosaic stored single-channel
        .rggb32float => f32,
        .rggb16uint => u16,
        .any => u16,
    };
}

pub fn Image(comptime desc: NodeDesc, comptime name: []const u8) type {
    const socket = desc.sockets[getSocketIdx(desc, name)];
    return *addrspace(.constant) const @SpirvType(.{ .image = .{
        .usage = toSpirvUsage(socket),
        .format = toSpirvImageFormat(socket.format),
        .dim = .@"2d",
        .depth = .not_depth,
        .arrayed = false,
        .multisampled = false,
        .access = .unknown,
    } });
}

pub fn getImageFromZon(comptime zon: NodeDesc, comptime name: []const u8) Image(zon, name) {
    const socket_idx = getSocketIdx(zon, name);
    return @extern(Image(zon, name), .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = 1, .binding = socket_idx } },
    });
}

/// Fetch a single texel from a *sampled* image at integer coordinates,
/// as a SPIR-V vector.
/// std.spirv has no counterpart to imageWrite() for reads: reading without a
/// sampler is OpImageFetch (OpImageRead is only valid for storage images, and
/// wgpu hands us the input as a sampled texture), so we wrap it by hand in the
/// same style as std.spirv.imageWrite.
/// image must be of type `Image`
pub inline fn imageFetchVector(image: anytype, coordinate: Vec2u32) Vec4f32 {
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

/// Fetch a single texel as the zlm `Vec4` type, with one self-contained asm
/// block of its own (it does not delegate to `imageFetchVector`).
/// image must be of type `Image`
pub inline fn imageFetch(image: anytype, coordinate: Vec2u32) math.Vec4 {
    const InputImage = @TypeOf(image);
    const lod: i32 = 0; // required image operand for non-multisampled fetches
    const texel = asm volatile (
        \\%in  = OpLoad %InputImage %image
        \\%ret = OpImageFetch %Vec4f32 %in %coordinate Lod %lod
        : [ret] "" (-> Vec4f32),
        : [InputImage] "t" (InputImage),
          [image] "" (image),
          [Vec4f32] "t" (Vec4f32),
          [coordinate] "" (coordinate),
          [lod] "" (lod),
    );
    return math.Vec4.new(texel[0], texel[1], texel[2], texel[3]);
}

/// Write a texel to a *storage* image, from a SPIR-V vector. Equivalent of
/// std.spirv.imageWrite, but as a local `inline fn` for two reasons on the
/// current Zig master:
///  - naga (wgpu's SPIR-V front-end) rejects OpImageWrite when the image is
///    anything other than a global variable, so the wrapper must be inlined;
///    the SPIR-V backend never inlines plain calls and miscompiles
///    @call(.always_inline) on 3-parameter functions.
///  - std.spirv.imageWrite is a regular (non-inline) function.
/// image must be of type `Image`
pub inline fn imageWriteVector(image: anytype, coordinate: Vec2u32, texel: Vec4f32) void {
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

/// Write a texel to a *storage* image, from the zlm `Vec4` type, with one
/// self-contained asm block that builds the SPIR-V vector from the four
/// scalars (it does not delegate to `imageWriteVector`).
/// image must be of type `Image`
pub inline fn imageWrite(image: anytype, coordinate: Vec2u32, texel: math.Vec4) void {
    const OutputImage = @TypeOf(image);
    asm volatile (
        \\%out = OpLoad %OutputImage %image
        \\%tex = OpCompositeConstruct %Vec4f32 %x %y %z %w
        \\       OpImageWrite %out %coordinate %tex
        :
        : [OutputImage] "t" (OutputImage),
          [image] "" (image),
          [x] "" (texel.x),
          [y] "" (texel.y),
          [z] "" (texel.z),
          [w] "" (texel.w),
          [Vec4f32] "t" (Vec4f32),
          [coordinate] "" (coordinate),
    );
}
