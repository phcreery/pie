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

pub fn size(t: type) usize {
    switch (t) {
        i32 => return 4,
        f32 => return 4,
        [3]f32 => return 12,
        [3][3]f32 => return 48,
        else => unreachable,
    }
}

pub fn alignment(t: type) usize {
    switch (t) {
        i32 => return 4,
        f32 => return 4,
        [3]f32 => return 16,
        [3][3]f32 => return 16,
        else => unreachable,
    }
}

pub fn writeBytes(buf: []u8, item: anytype) void {
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

        // print
        // std.debug.print(
        //     "Field {s}: offset {d}, size {d}, align {d}\n",
        //     .{ field.name, i, field_size, field_align },
        // );

        i += field_size;
    }

    // round up i to alignment of struct_alignment
    const align_offset = @mod(i, struct_alignment);
    if (align_offset != 0) {
        i += struct_alignment - align_offset;
    }

    // return len
    return i;
}

// =================
// Structured as Tagged Union for dynamic data
// =================

pub const ParamValueTag = enum {
    i32,
    f32,
};
pub const ParamValue = union(ParamValueTag) {
    i32: i32,
    f32: f32,

    pub fn size_(self: ParamValue) usize {
        return switch (self) {
            .i32 => size(i32),
            .f32 => size(f32),
        };
    }

    pub fn alignment_(self: ParamValue) usize {
        return switch (self) {
            .i32 => alignment(i32),
            .f32 => alignment(f32),
        };
    }

    // pub fn asBytes(self: *const ParamValue) []u8 {
    //     return switch (self.*) {
    //         // .i32 => @ptrCast(@alignCast(@constCast(&self.i32))), // or std.mem.asBytes()
    //         .i32 => std.mem.asBytes(@constCast(&self.i32)),
    //         .f32 => std.mem.asBytes(@constCast(&self.f32)),
    //     };
    // }
    pub fn writeBytes(self: ParamValue, buf: []u8) void {
        switch (self) {
            .i32 => {
                const bytes = std.mem.asBytes(@constCast(&self.i32))[0..size(i32)];
                @memcpy(buf[0..bytes.len], bytes);
            },
            .f32 => {
                const bytes = std.mem.asBytes(@constCast(&self.f32))[0..size(f32)];
                @memcpy(buf[0..bytes.len], bytes);
            },
        }
    }
    pub fn set(self: *ParamValue, value: ParamValue) !void {
        if (std.meta.activeTag(self.*) != std.meta.activeTag(value)) {
            return error.ParamTypeMismatch;
        }
        switch (value) {
            .i32 => {
                self.* = .{ .i32 = value.i32 };
            },
            .f32 => {
                self.* = .{ .f32 = value.f32 };
            },
        }
    }
};

// Params
pub fn layoutTaggedUnion(maybe_buf: ?[]u8, tu: []ParamValue) !usize {
    var i: usize = 0;

    for (tu) |param| {
        const param_align = param.alignment_();
        const param_size = param.size_();

        // align i to param_align
        const align_offset = @mod(i, param_align);
        if (align_offset != 0) {
            i += param_align - align_offset;
        }

        if (maybe_buf) |buf| {
            param.writeBytes(buf[i..]);
        }

        // print
        // std.debug.print(
        //     "Param: offset {d}, size {d}, align {d}\n",
        //     .{ i, param_size, param_align },
        // );

        i += param_size;
    }

    // round up i to alignment of largest param
    var struct_alignment: usize = 0;
    for (tu) |param| {
        const param_align = param.alignment_();
        if (param_align > struct_alignment) {
            struct_alignment = param_align;
        }
    }
    const align_offset = @mod(i, struct_alignment);
    if (align_offset != 0) {
        i += struct_alignment - align_offset;
    }

    // return len
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

test "layoutTaggedUnion" {
    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    var tu = [_]ParamValue{
        .{ .f32 = 3.14 },
        .{ .i32 = 42 },
        .{ .f32 = 2.718 },
    };
    const used_len = try layoutTaggedUnion(buf, tu[0..]);
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

    try std.testing.expectEqual(12, bytes_buf.len);

    const expect_f32_1: f32 = 3.14;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_f32_1)[0..4], bytes_buf[0..4]);

    const expect_i32: i32 = 42;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_i32)[0..4], bytes_buf[4..8]);

    const expect_f32_2: f32 = 2.718;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expect_f32_2)[0..4], bytes_buf[8..12]);
}
