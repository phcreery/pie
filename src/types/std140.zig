//! std140-style packing shared by the CPU packer (`layoutStruct`) and
//! the Zig→SPIR-V shaders that bind the packed struct as a uniform buffer.
//!
//! `GpuStruct` turns a CPU struct of f32/i32/enums, `[4]f32` vec4s and
//! `[3][3]f32` matrices into the extern struct a shader can `@extern`: exactly
//! the offsets `layoutStruct` writes, but spelled with types SPIR-V and naga
//! accept (vectors are illegal in extern structs, and a uniform block rejects
//! `array<f32, N>` members because their stride would be 4, not 16).

// https://webgpufundamentals.org/webgpu/lessons/webgpu-memory-layout.html
// see: https://github.com/greggman/webgpu-utils/blob/3f1a4561622ea53e160b91de0d2a196443722dfd/src/wgsl-types.ts#L22

// | type         | size | align |
// |--------------|------|-------|
// | i32          | 4    | 4     |
// | u32          | 4    | 4     |
// | f32          | 4    | 4     |
// | f16          | 2    | 2     |
// | vec2<i32>    | 8    | 8     |
// | vec2<u32>    | 8    | 8     |
// | vec2<f32>    | 8    | 8     |
// | vec2<f16>    | 4    | 4     |
// | vec3<i32>    | 12   | 16    |
// | vec3<u32>    | 12   | 16    |
// | vec3<f32>    | 12   | 16    |
// | vec3<f16>    | 6    | 8     |
// | vec4<i32>    | 16   | 16    |
// | vec4<u32>    | 16   | 16    |
// | vec4<f32>    | 16   | 16    |
// | vec4<f16>    | 8    | 8     |
// | mat2x2<f32>  | 16   | 8     |
// | mat2x2<f16>  | 8    | 4     |
// | mat3x2<f32>  | 24   | 8     |
// | mat3x2<f16>  | 12   | 4     |
// | mat4x2<f32>  | 32   | 8     |
// | mat4x2<f16>  | 16   | 4     |
// | mat2x3<f32>  | 32   | 16    |
// | mat2x3<f16>  | 16   | 8     |
// | mat3x3<f32>  | 48   | 16    |
// | mat3x3<f16>  | 24   | 8     |
// | mat4x3<f32>  | 64   | 16    |
// | mat4x3<f16>  | 32   | 8     |
// | mat2x4<f32>  | 32   | 16    |
// | mat2x4<f16>  | 16   | 8     |
// | mat3x4<f32>  | 48   | 16    |
// | mat3x4<f16>  | 24   | 8     |
// | mat4x4<f32>  | 64   | 16    |
// | mat4x4<f16>  | 32   | 8     |

// | type                          | align                                             | size                                       |
// | ----------------------------- | ------------------------------------------------- | ------------------------------------------ |
// | struct S with members M1...MN | max(AlignOfMember(S,1), ... , AlignOfMember(S,N)) | roundUp(AlignOf(S), justPastLastMember) ** |
// | array<E, N>                   | AlignOf(E)                                        | N * roundUp(AlignOf(E), SizeOf(E))         |

// **where justPastLastMember = OffsetOfMember(S,N) + SizeOfMember(S,N)

const std = @import("std");
const slog = std.log.scoped(.std140);

pub const Vec3 = vecType(3);
pub const Vec4 = vecType(4);

/// std140 `mat3x3<f32>`: three 16-byte columns. Column `cN` holds row `N` of the
/// CPU matrix, because `layoutStruct` pads each CPU row to 16 bytes.
pub const Mat3x3 = structType(
    &[_][:0]const u8{ "c0", "c1", "c2" },
    &[_]type{ Vec4, Vec4, Vec4 },
    &[_]std.builtin.Type.Struct.FieldAttributes{
        .{ .@"align" = 16 },
        .{ .@"align" = 16 },
        .{ .@"align" = 16 },
    },
);

/// Byte size `layoutStruct` advances for a value of type `T`.
pub fn size(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| size(e.tag_type),
        .int, .float => 4,
        .array => |a| blk: {
            if (a.child == f32) {
                if (a.len == 3 or a.len == 4) break :blk a.len * @sizeOf(f32);
                @compileError("std140.size: unsupported vector type '" ++ @typeName(T) ++ "'");
            }
            if (a.child == [3]f32 and a.len == 3) break :blk 48; // rows padded to 16
            @compileError("std140.size: unsupported array type '" ++ @typeName(T) ++ "'");
        },
        else => @compileError("std140.size: unsupported type '" ++ @typeName(T) ++ "'"),
    };
}

/// Byte alignment `layoutStruct` gives a value of type `T`.
pub fn alignment(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| alignment(e.tag_type),
        .int, .float => 4,
        .array => |a| blk: {
            if (a.child == f32) {
                if (a.len == 3 or a.len == 4) break :blk 16;
                @compileError("std140.alignment: unsupported vector type '" ++ @typeName(T) ++ "'");
            }
            if (a.child == [3]f32 and a.len == 3) break :blk 16;
            @compileError("std140.alignment: unsupported array type '" ++ @typeName(T) ++ "'");
        },
        else => @compileError("std140.alignment: unsupported type '" ++ @typeName(T) ++ "'"),
    };
}

/// The extern-struct spelling of `Cpu` that a shader can bind. Every field sits
/// at the offset `layoutStruct` writes it to; that equality is checked at
/// comptime.
pub fn GpuStruct(comptime Cpu: type) type {
    const names = std.meta.fieldNames(Cpu);
    const field_types = std.meta.fieldTypes(Cpu);

    var gpu_names: [names.len][:0]const u8 = undefined;
    var gpu_types: [names.len]type = undefined;
    var gpu_attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;

    inline for (field_types, 0..) |T, i| {
        gpu_names[i] = names[i];
        gpu_types[i] = gpuFieldType(T);
        gpu_attrs[i] = .{ .@"align" = alignment(T) };
    }

    const Gpu = structType(&gpu_names, &gpu_types, &gpu_attrs);

    comptime {
        var offset: usize = 0;
        var struct_alignment: usize = 1;
        for (field_types, 0..) |T, i| {
            const field_alignment = alignment(T);
            struct_alignment = @max(struct_alignment, field_alignment);
            offset = std.mem.alignForward(usize, offset, field_alignment);
            if (@offsetOf(Gpu, names[i]) != offset) {
                @compileError("std140.GpuStruct: " ++ names[i] ++ " is at the wrong offset");
            }
            offset += size(T);
        }
        if (@sizeOf(Gpu) != std.mem.alignForward(usize, offset, struct_alignment)) {
            @compileError("std140.GpuStruct: " ++ @typeName(Cpu) ++ " has the wrong size");
        }
    }

    return Gpu;
}

fn gpuFieldType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .float, .int, .@"enum" => T,
        .array => |a| blk: {
            if (a.child == f32) {
                switch (a.len) {
                    3 => break :blk Vec3,
                    4 => break :blk Vec4,
                    else => @compileError("std140.GpuStruct: unsupported vector '" ++ @typeName(T) ++ "'"),
                }
            }
            if (a.child == [3]f32 and a.len == 3) break :blk Mat3x3;
            @compileError("std140.GpuStruct: unsupported array '" ++ @typeName(T) ++ "'");
        },
        else => @compileError("std140.GpuStruct: unsupported field type '" ++ @typeName(T) ++ "'"),
    };
}

fn vecType(comptime n: usize) type {
    const all_names = [_][:0]const u8{ "x", "y", "z", "w" };
    var names: [n][:0]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.builtin.Type.Struct.FieldAttributes = undefined;
    inline for (0..n) |i| {
        names[i] = all_names[i];
        types[i] = f32;
        attrs[i] = .{};
    }
    return structType(&names, &types, &attrs);
}

fn structType(
    comptime names: []const [:0]const u8,
    comptime types: []const type,
    comptime attrs: []const std.builtin.Type.Struct.FieldAttributes,
) type {
    return @Struct(.@"extern", null, names, types, attrs);
}

pub fn writeBytes(buf: []u8, item: anytype) void {
    // if t is enum, we need to get the alignment of the underlying value (e.g. i32)
    if (@typeInfo(@TypeOf(item)) == .@"enum") {
        const underlying = @backingInt(item);
        writeBytes(buf, underlying);
        return;
    }
    switch (@TypeOf(item)) {
        f32 => {
            const bytes = std.mem.asBytes(@constCast(&item))[0..size(@TypeOf(item))];
            @memcpy(buf[0..bytes.len], bytes);
        },
        i32 => {
            const bytes = std.mem.asBytes(@constCast(&item))[0..size(@TypeOf(item))];
            @memcpy(buf[0..bytes.len], bytes);
        },
        [3]f32 => {
            const bytes = std.mem.asBytes(@constCast(&item))[0..size(@TypeOf(item))];
            @memcpy(buf[0..bytes.len], bytes);
        },
        [4]f32 => {
            const bytes = std.mem.asBytes(@constCast(&item))[0..size(@TypeOf(item))];
            @memcpy(buf[0..bytes.len], bytes);
        },
        [3][3]f32 => {
            // need to pad each vec3 row to 16 bytes
            var offset: usize = 0;
            inline for (item) |row| {
                const row_bytes = std.mem.asBytes(@constCast(&row))[0..size(@TypeOf(row))];
                @memcpy(buf[offset .. offset + row_bytes.len], row_bytes);
                offset += alignment(@TypeOf(item)); // pad to 16 bytes
            }
        },
        else => unreachable,
    }
}

// ImgParams
pub fn layoutStruct(maybe_buf: ?[]u8, s: anytype) !usize {
    var i: usize = 0;
    var struct_alignment: usize = 0;

    const s_type = @TypeOf(s);
    const f_types = comptime std.meta.fieldTypes(s_type);
    inline for (f_types) |field_type| {
        const field_align = alignment(field_type);
        if (field_align > struct_alignment) {
            struct_alignment = field_align;
        }
    }

    // loop through fields of s
    inline for (f_types, 0..) |field_type, j| {
        const field_align = alignment(field_type);
        const field_size = size(field_type);

        // align i to field_align
        const align_offset = @mod(i, field_align);
        if (align_offset != 0) {
            i += field_align - align_offset;
        }

        const field_value = @field(s, std.meta.fieldNames(@TypeOf(s))[j]);
        if (maybe_buf) |buf| {
            writeBytes(buf[i..], field_value);
        }

        i += field_size;
    }

    // round up i to alignment of struct_alignment
    const align_offset = @mod(i, struct_alignment);
    if (align_offset != 0) {
        i += struct_alignment - align_offset;
    }

    return i;
}

test "layoutStruct" {
    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    const S = struct {
        float: f32 = 3.14,
        vec3: [3]f32 = .{ 1.0, 2.0, 3.0 },
        mat3x3: [3][3]f32 = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        },
    };
    const used_len = try layoutStruct(buf, S{});
    const bytes_buf = buf[0..used_len];

    std.debug.print("Used length: {d}\n", .{bytes_buf.len});
    // print bytes
    for (bytes_buf, 0..) |b, idx| {
        std.debug.print("{x:0>2} ", .{b});
        if ((idx + 1) % 4 == 0) {
            std.debug.print(" ", .{});
        }
        if ((idx + 1) % 16 == 0) {
            std.debug.print("\n", .{});
        }
    }
    std.debug.print("\n", .{});

    try std.testing.expectEqual(80, bytes_buf.len);

    const expect_float: f32 = 3.14;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_float)[0..], bytes_buf[0..4]);

    const expect_vec3: [3]f32 = .{ 1.0, 2.0, 3.0 };
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_vec3)[0..12], bytes_buf[16..28]);

    const expect_mat3x3_r1: [3]f32 = .{ 1.0, 0.0, 0.0 };
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_mat3x3_r1)[0..12], bytes_buf[32..44]);

    const expect_mat3x3_r2: [3]f32 = .{ 0.0, 1.0, 0.0 };
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_mat3x3_r2)[0..12], bytes_buf[48..60]);
}

test "layoutStruct packs ImgParams as its std140 GPU view" {
    const ImgParam = @import("ImgParam.zig");
    const Cpu = ImgParam.ImgParams;
    const Gpu = ImgParam.ImgParamsGpu;

    const rec2020: [3][3]f32 = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } };
    const xyz: [3][3]f32 = .{ .{ 9, 8, 7 }, .{ 6, 5, 4 }, .{ 3, 2, 1 } };
    const params: Cpu = .{
        .black = .{ 0.1, 0.2, 0.3, 0.4 },
        .white = .{ 1.1, 1.2, 1.3, 1.4 },
        .white_balance = .{ 2.1, 2.2, 2.3, 2.4 },
        .orientation = .rotate90CW,
        .rec2020_from_cam = rec2020,
        .xyz_d65_from_cam = xyz,
    };

    var buf: [@sizeOf(Gpu)]u8 = @splat(0);
    try std.testing.expectEqual(@sizeOf(Gpu), try layoutStruct(&buf, params));

    // Zeroed so the struct's padding (vec4 `w`, 16-byte matrix padding) matches
    // the untouched padding bytes the packer leaves behind.
    var expected: Gpu = undefined;
    @memset(std.mem.asBytes(&expected), 0);
    expected.black = .{ .x = 0.1, .y = 0.2, .z = 0.3, .w = 0.4 };
    expected.white = .{ .x = 1.1, .y = 1.2, .z = 1.3, .w = 1.4 };
    expected.white_balance = .{ .x = 2.1, .y = 2.2, .z = 2.3, .w = 2.4 };
    expected.orientation = .rotate90CW;
    expected.rec2020_from_cam = .{
        .c0 = .{ .x = rec2020[0][0], .y = rec2020[0][1], .z = rec2020[0][2], .w = 0 },
        .c1 = .{ .x = rec2020[1][0], .y = rec2020[1][1], .z = rec2020[1][2], .w = 0 },
        .c2 = .{ .x = rec2020[2][0], .y = rec2020[2][1], .z = rec2020[2][2], .w = 0 },
    };
    expected.xyz_d65_from_cam = .{
        .c0 = .{ .x = xyz[0][0], .y = xyz[0][1], .z = xyz[0][2], .w = 0 },
        .c1 = .{ .x = xyz[1][0], .y = xyz[1][1], .z = xyz[1][2], .w = 0 },
        .c2 = .{ .x = xyz[2][0], .y = xyz[2][1], .z = xyz[2][2], .w = 0 },
    };

    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), &buf);
}
