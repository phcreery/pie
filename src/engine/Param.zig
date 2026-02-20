const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const gpu_data = @import("gpu_data.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.param);

pub fn Param(T: type) type {
    return struct {
        name: []const u8,
        value: T,
    };
}

// ImgParams
pub fn layoutParams(maybe_buf: ?[]u8, params: []Param) !usize {
    var i: usize = 0;
    var struct_alignment: usize = 0;

    for (params) |param| {
        const param_align = gpu_data.alignment(@TypeOf(param.value));
        const param_size = gpu_data.size(@TypeOf(param.value));

        // align i to param_align
        const align_offset = @mod(i, param_align);
        if (align_offset != 0) {
            i += param_align - align_offset;
        }

        if (maybe_buf) |buf| {
            param.writeBytes(buf[i..]);
        }

        i += param_size;
    }

    // inline for (std.meta.fields(@TypeOf(p))) |field| {
    for (params) |param| {
        const field_align = gpu_data.alignment(param.type);
        if (field_align > struct_alignment) {
            struct_alignment = field_align;
        }
    }

    // loop through fields of s
    inline for (std.meta.fields(@TypeOf(params))) |field| {
        const field_align = gpu_data.alignment(field.type);
        const field_size = gpu_data.size(field.type);

        // align i to field_align
        const align_offset = @mod(i, field_align);
        if (align_offset != 0) {
            i += field_align - align_offset;
        }

        const field_value = @field(params, field.name);
        if (maybe_buf) |buf| {
            gpu_data.writeBytes(buf[i..], field_value);
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

// params is an array of .{ .name: []const u8, .value: T }
pub fn layoutAnonArrParams(maybe_buf: ?[]u8, params: anytype) !usize {
    var i: usize = 0;
    var struct_alignment: usize = 0;

    inline for (params) |param| {
        // @compileLog(@TypeOf(param.value));
        const param_align = gpu_data.alignment(@TypeOf(param.value));
        const param_size = gpu_data.size(@TypeOf(param.value));

        // align i to param_align
        const align_offset = @mod(i, param_align);
        if (align_offset != 0) {
            i += param_align - align_offset;
        }

        if (maybe_buf) |buf| {
            gpu_data.writeBytes(buf[i..], param.value);
        }

        i += param_size;
    }

    // inline for (std.meta.fields(@TypeOf(p))) |field| {
    inline for (params) |param| {
        const field_align = gpu_data.alignment(@TypeOf(param.value));
        if (field_align > struct_alignment) {
            struct_alignment = field_align;
        }
    }

    // round up i to alignment of struct_alignment
    const align_offset = @mod(i, struct_alignment);
    if (align_offset != 0) {
        i += struct_alignment - align_offset;
    }

    // return len
    return i;
}

// test "Param module init" {
//     const p = Param(f32){ .name = "a", .value = 3.14 };

//     try std.testing.expect(p.value == 3.14);
// }

test "anon arra params" {
    // layoutAnonArrParams

    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    // const S = struct {
    //     float: f32 = 3.14,
    //     vec3: [3]f32 = .{ 1.0, 2.0, 3.0 },
    //     mat3x3: [3][3]f32 = .{
    //         .{ 1.0, 0.0, 0.0 },
    //         .{ 0.0, 1.0, 0.0 },
    //         .{ 0.0, 0.0, 1.0 },
    //     },
    // };
    const params = .{
        .{ .name = "float", .value = @as(f32, 3.14) },
        .{ .name = "vec3", .value = [3]f32{ 1.0, 2.0, 3.0 } },
        .{ .name = "mat3x3", .value = [3][3]f32{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        } },
    };
    const used_len = try layoutAnonArrParams(buf, params);
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
