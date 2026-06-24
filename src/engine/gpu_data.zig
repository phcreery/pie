const std = @import("std");
const slog = std.log.scoped(.gpu);

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

pub fn size(T: type) usize {
    // if t is enum, we need to get the size of the underlying type (e.g. i32)
    // std.builtin.Type
    if (@typeInfo(T) == .@"enum") {
        const underlying = @typeInfo(T).@"enum".tag_type;
        return size(underlying);
    }
    switch (T) {
        i32 => return 4,
        f32 => return 4,
        [3]f32 => return 12,
        [4]f32 => return 16,
        [3][3]f32 => return 48,
        else => unreachable,
    }
}

pub fn alignment(T: type) usize {
    // if t is enum, we need to get the alignment of the underlying type (e.g. i32)
    if (@typeInfo(T) == .@"enum") {
        const underlying = @typeInfo(T).@"enum".tag_type;
        return alignment(underlying);
    }
    switch (T) {
        i32 => return 4,
        f32 => return 4,
        [3]f32 => return 16,
        [4]f32 => return 16,
        [3][3]f32 => return 16,
        else => unreachable,
    }
}

pub fn writeBytes(buf: []u8, item: anytype) void {
    // if t is enum, we need to get the alignment of the underlying value (e.g. i32)
    if (@typeInfo(@TypeOf(item)) == .@"enum") {
        const underlying = @intFromEnum(item);
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

    inline for (std.meta.fields(@TypeOf(s))) |field| {
        const field_align = alignment(field.type);
        if (field_align > struct_alignment) {
            struct_alignment = field_align;
        }
    }

    // loop through fields of s
    inline for (std.meta.fields(@TypeOf(s))) |field| {
        const field_align = alignment(field.type);
        const field_size = size(field.type);

        // align i to field_align
        const align_offset = @mod(i, field_align);
        if (align_offset != 0) {
            i += field_align - align_offset;
        }

        const field_value = @field(s, field.name);
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
