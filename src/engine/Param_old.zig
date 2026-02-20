const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const gpu_data = @import("gpu_data.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.param);

// =================
// Structured as Tagged Union for dynamic data
// =================

pub const ParamValueTag = enum {
    i32,
    f32,
    str,
};
pub const ParamValue = union(ParamValueTag) {
    i32: i32,
    f32: f32,
    str: [4]u8,
};
const Self = @This();

name: []const u8,
value: ParamValue,
len: i32,

pub fn init(name: []const u8, value: ParamValue, len: i32) Self {
    return Self{
        .name = name,
        .value = value,
        .len = len,
    };
}

pub fn size(self: Self) usize {
    return switch (self.value) {
        .i32 => switch (self.len) {
            1 => gpu_data.size(i32),
            // 2 => gpu_data.size([2]i32)
            else => unreachable,
        },
        .f32 => switch (self.len) {
            1 => gpu_data.size(f32),
            else => unreachable,
        },
        else => unreachable,
    };
}

pub fn alignment(self: Self) usize {
    return switch (self.value) {
        .i32 => switch (self.len) {
            1 => gpu_data.alignment(i32),
            else => unreachable,
        },
        .f32 => switch (self.len) {
            1 => gpu_data.alignment(f32),
            else => unreachable,
        },
        else => unreachable,
    };
}

pub fn writeBytes(self: Self, buf: []u8) void {
    switch (self.value) {
        .i32 => {
            const bytes = std.mem.asBytes(@constCast(&self.value.i32))[0..self.size()];
            @memcpy(buf[0..bytes.len], bytes);
        },
        .f32 => {
            const bytes = std.mem.asBytes(@constCast(&self.value.f32))[0..self.size()];
            @memcpy(buf[0..bytes.len], bytes);
        },
        else => unreachable,
    }
}
pub fn set(self: *Self, value: ParamValue) !void {
    if (std.meta.activeTag(self.*.value) != std.meta.activeTag(value)) {
        return error.ParamTypeMismatch;
    }
    switch (value) {
        .i32 => {
            self.* = .{ .i32 = value.i32 };
        },
        .f32 => {
            self.* = .{ .f32 = value.f32 };
        },
        else => unreachable,
    }
}

// Params
pub fn layoutTaggedUnion(maybe_buf: ?[]u8, tu: []Self) !usize {
    var i: usize = 0;

    for (tu) |param| {
        const param_align = param.alignment();
        const param_size = param.size();

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

    // round up i to alignment of largest param
    var struct_alignment: usize = 0;
    for (tu) |param| {
        const param_align = param.alignment();
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

test "layoutTaggedUnion" {
    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    var tu = [_]Self{
        .{ .name = "a", .value = .{ .f32 = 3.14 }, .len = 1 },
        .{ .name = "a", .value = .{ .i32 = 42 }, .len = 1 },
        .{ .name = "a", .value = .{ .f32 = 2.718 }, .len = 1 },
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

test "Param module init" {
    const Param = @This();
    const param = Param.init("test_param", .{
        .f32 = 3.14,
    }, 1);

    switch (param.value) {
        .f32 => |v| {
            try std.testing.expect(v == 3.14);
        },
        else => {
            try std.testing.expect(false);
        },
    }
}

test "Param module init 2" {
    const Param = @This();
    const param: Param = .{ .name = "test_param", .value = .{ .i32 = 314 }, .len = 1 };
    slog.info("Param value size: {any}", .{param.size()});

    switch (param.value) {
        .i32 => |v| {
            try std.testing.expect(v == 314);
        },
        else => {
            try std.testing.expect(false);
        },
    }
}
