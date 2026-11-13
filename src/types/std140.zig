//! std140-style packing shared by the CPU packer (`layoutStruct`) and
//! the Zig→SPIR-V shaders that bind the packed struct as a uniform buffer.
//!
//! `GpuStruct` turns a CPU struct of f32/i32/enums, float vectors and 3x3
//! matrices into the extern struct a shader can `@extern`. The offsets are
//! exactly the offsets `layoutStruct` writes. The types are spelled the way
//! SPIR-V and naga accept them: vectors are illegal in extern structs, and a
//! uniform block rejects `array<f32, N>` members because their stride would
//! be 4, not 16.
//!
//! Vectors and matrices are recognized by shape, not by type name. A vector is
//! `[N]T` or a struct of `N` `T` fields named `x`/`y`/`z`/`w`. A matrix is
//! `[cols][rows]T` or a struct that holds one.
//!
//! `scalarLayout`, `vecLayout` and `matLayout` cover every row of the table
//! below. Add a scalar row to support a new scalar in all shapes.

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

pub const Vec3 = vecType(f32, 3);
pub const Vec4 = vecType(f32, 4);

/// std140 `mat3x3<f32>`: three 16-byte columns. Column `cN` holds row `N` of the
/// CPU matrix, because `layoutStruct` pads each CPU row to 16 bytes.
pub const Mat3x3 = matType(f32, 3, 3);

/// std140 size and alignment of one value.
const Layout = struct { size: usize, alignment: usize };

/// Scalar rows from the header table. Add a row here to support a new scalar
/// in every vector and matrix shape.
fn scalarLayout(comptime T: type) ?Layout {
    return switch (T) {
        f16 => .{ .size = 2, .alignment = 2 },
        f32, i32, u32 => .{ .size = 4, .alignment = 4 },
        else => null,
    };
}

/// `vecN<T>`: `N` components. The alignment rounds `N` up to a power of two.
fn vecLayout(comptime T: type, comptime n: usize) Layout {
    const scalar = scalarLayout(T).?;
    const lanes = if (n == 2) 2 else 4;
    return .{ .size = n * scalar.size, .alignment = lanes * scalar.alignment };
}

/// `matCxR<T>`: `C` columns of `vecR<T>`. Each column pads to its alignment.
fn matLayout(comptime T: type, comptime cols: usize, comptime rows: usize) Layout {
    const column = vecLayout(T, rows);
    return .{
        .size = cols * std.mem.alignForward(usize, column.size, column.alignment),
        .alignment = column.alignment,
    };
}

const Vec = struct { elem: type, len: usize };
const Mat = struct { elem: type, cols: usize, rows: usize };

/// std140 class of a CPU field type. The type library does not matter.
const Kind = union(enum) {
    scalar: type,
    vec: Vec,
    mat: Mat,

    fn layout(comptime kind: Kind) Layout {
        return switch (kind) {
            .scalar => |T| scalarLayout(T).?,
            .vec => |v| vecLayout(v.elem, v.len),
            .mat => |m| matLayout(m.elem, m.cols, m.rows),
        };
    }
};

const vec_names = [_][:0]const u8{ "x", "y", "z", "w" };
const mat_names = [_][:0]const u8{ "c0", "c1", "c2", "c3" };

/// A vector is `[N]T` or a struct of `N` `T` fields named `x`/`y`/`z`/`w`.
fn vecOf(comptime T: type) ?Vec {
    return switch (@typeInfo(T)) {
        .array => |a| if (a.len >= 2 and a.len <= 4 and scalarLayout(a.child) != null)
            .{ .elem = a.child, .len = a.len }
        else
            null,
        .@"struct" => |s| blk: {
            if (s.field_types.len < 2 or s.field_types.len > 4) break :blk null;
            const elem = s.field_types[0];
            if (scalarLayout(elem) == null) break :blk null;
            inline for (0..s.field_types.len) |i| {
                if (s.field_types[i] != elem or !std.mem.eql(u8, s.field_names[i], vec_names[i])) break :blk null;
            }
            break :blk .{ .elem = elem, .len = s.field_types.len };
        },
        else => null,
    };
}

/// A matrix is `[cols][rows]T` or a struct that holds one.
fn matOf(comptime T: type) ?Mat {
    return switch (@typeInfo(T)) {
        .array => |a| blk: {
            const row = switch (@typeInfo(a.child)) {
                .array => |r| r,
                else => break :blk null,
            };
            if (a.len < 2 or a.len > 4 or row.len < 2 or row.len > 4) break :blk null;
            if (scalarLayout(row.child) == null) break :blk null;
            break :blk .{ .elem = row.child, .cols = a.len, .rows = row.len };
        },
        .@"struct" => |s| if (s.field_types.len == 1) matOf(s.field_types[0]) else null,
        else => null,
    };
}

fn unsupported(comptime T: type, comptime context: []const u8) noreturn {
    @compileError(context ++ ": unsupported type '" ++ @typeName(T) ++ "'");
}

/// Classify `T` by shape. The header table defines the supported shapes.
fn kindOf(comptime T: type, comptime context: []const u8) Kind {
    return switch (@typeInfo(T)) {
        .int, .float => blk: {
            if (scalarLayout(T) == null) unsupported(T, context);
            break :blk .{ .scalar = T };
        },
        .@"enum" => |e| blk: {
            if (scalarLayout(e.tag_type) == null) unsupported(T, context);
            break :blk .{ .scalar = e.tag_type };
        },
        .array, .@"struct" => if (vecOf(T)) |v|
            .{ .vec = v }
        else if (matOf(T)) |m|
            .{ .mat = m }
        else
            unsupported(T, context),
        else => unsupported(T, context),
    };
}

/// Byte size `layoutStruct` advances for a value of type `T`.
pub fn size(comptime T: type) usize {
    const kind = comptime kindOf(T, "std140.size");
    return kind.layout().size;
}

/// Byte alignment `layoutStruct` gives a value of type `T`.
pub fn alignment(comptime T: type) usize {
    const kind = comptime kindOf(T, "std140.alignment");
    return kind.layout().alignment;
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
    const kind = comptime kindOf(T, "std140.GpuStruct");
    return switch (kind) {
        .scalar => T,
        .vec => |v| vecType(v.elem, v.len),
        .mat => |m| matType(m.elem, m.cols, m.rows),
    };
}

fn vecType(comptime elem: type, comptime n: usize) type {
    var types: [n]type = undefined;
    var attrs: [n]std.builtin.Type.Struct.FieldAttributes = undefined;
    inline for (0..n) |i| {
        types[i] = elem;
        attrs[i] = .{};
    }
    return structType(vec_names[0..n], &types, &attrs);
}

fn matType(comptime elem: type, comptime cols: usize, comptime rows: usize) type {
    const lanes = if (rows == 2) 2 else 4;
    const column = vecType(elem, lanes);
    const column_align = vecLayout(elem, rows).alignment;
    var types: [cols]type = undefined;
    var attrs: [cols]std.builtin.Type.Struct.FieldAttributes = undefined;
    inline for (0..cols) |c| {
        types[c] = column;
        attrs[c] = .{ .@"align" = column_align };
    }
    return structType(mat_names[0..cols], &types, &attrs);
}

fn structType(
    comptime names: []const [:0]const u8,
    comptime types: []const type,
    comptime attrs: []const std.builtin.Type.Struct.FieldAttributes,
) type {
    return @Struct(.@"extern", null, names, types, attrs);
}

pub fn writeBytes(buf: []u8, item: anytype) void {
    const T = @TypeOf(item);
    if (@typeInfo(T) == .@"enum") {
        writeScalar(buf, @backingInt(item));
        return;
    }
    const kind = comptime kindOf(T, "std140.writeBytes");
    switch (kind) {
        .scalar => writeScalar(buf, item),
        .vec => |v| switch (@typeInfo(T)) {
            .array => inline for (0..v.len) |i| writeScalar(buf[i * @sizeOf(v.elem) ..], item[i]),
            .@"struct" => |s| inline for (0..v.len) |i| writeScalar(buf[i * @sizeOf(v.elem) ..], @field(item, s.field_names[i])),
            else => unreachable,
        },
        .mat => |m| {
            const matrix: [m.cols][m.rows]m.elem = switch (@typeInfo(T)) {
                .array => item,
                .@"struct" => |s| @field(item, s.field_names[0]),
                else => unreachable,
            };
            const stride = matLayout(m.elem, m.cols, m.rows).alignment;
            inline for (matrix, 0..) |column, c| {
                inline for (column, 0..) |component, r| {
                    writeScalar(buf[c * stride + r * @sizeOf(m.elem) ..], component);
                }
            }
        },
    }
}

/// Copy the bytes of one scalar value to `buf`.
fn writeScalar(buf: []u8, value: anytype) void {
    const bytes = std.mem.toBytes(value);
    @memcpy(buf[0..bytes.len], &bytes);
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

test "layout matches the header table" {
    const Row = struct { T: type, size: usize, alignment: usize };
    const rows = [_]Row{
        .{ .T = i32, .size = 4, .alignment = 4 },
        .{ .T = u32, .size = 4, .alignment = 4 },
        .{ .T = f32, .size = 4, .alignment = 4 },
        .{ .T = f16, .size = 2, .alignment = 2 },
        .{ .T = [2]i32, .size = 8, .alignment = 8 },
        .{ .T = [2]u32, .size = 8, .alignment = 8 },
        .{ .T = [2]f32, .size = 8, .alignment = 8 },
        .{ .T = [2]f16, .size = 4, .alignment = 4 },
        .{ .T = [3]i32, .size = 12, .alignment = 16 },
        .{ .T = [3]u32, .size = 12, .alignment = 16 },
        .{ .T = [3]f32, .size = 12, .alignment = 16 },
        .{ .T = [3]f16, .size = 6, .alignment = 8 },
        .{ .T = [4]i32, .size = 16, .alignment = 16 },
        .{ .T = [4]u32, .size = 16, .alignment = 16 },
        .{ .T = [4]f32, .size = 16, .alignment = 16 },
        .{ .T = [4]f16, .size = 8, .alignment = 8 },
        .{ .T = [2][2]f32, .size = 16, .alignment = 8 },
        .{ .T = [2][2]f16, .size = 8, .alignment = 4 },
        .{ .T = [3][2]f32, .size = 24, .alignment = 8 },
        .{ .T = [3][2]f16, .size = 12, .alignment = 4 },
        .{ .T = [4][2]f32, .size = 32, .alignment = 8 },
        .{ .T = [4][2]f16, .size = 16, .alignment = 4 },
        .{ .T = [2][3]f32, .size = 32, .alignment = 16 },
        .{ .T = [2][3]f16, .size = 16, .alignment = 8 },
        .{ .T = [3][3]f32, .size = 48, .alignment = 16 },
        .{ .T = [3][3]f16, .size = 24, .alignment = 8 },
        .{ .T = [4][3]f32, .size = 64, .alignment = 16 },
        .{ .T = [4][3]f16, .size = 32, .alignment = 8 },
        .{ .T = [2][4]f32, .size = 32, .alignment = 16 },
        .{ .T = [2][4]f16, .size = 16, .alignment = 8 },
        .{ .T = [3][4]f32, .size = 48, .alignment = 16 },
        .{ .T = [3][4]f16, .size = 24, .alignment = 8 },
        .{ .T = [4][4]f32, .size = 64, .alignment = 16 },
        .{ .T = [4][4]f16, .size = 32, .alignment = 8 },
    };
    inline for (rows) |row| {
        try std.testing.expectEqual(row.size, size(row.T));
        try std.testing.expectEqual(row.alignment, alignment(row.T));
    }
}
