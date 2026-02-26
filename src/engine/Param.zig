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
    // vec2_f32,
    f32,
    str,
};

const Self = @This();

desc: api.ParamDesc,
bytes: []u8, // we will store the value as bytes, and interpret it based on the type

pub fn init(allocator: std.mem.Allocator, desc: api.ParamDesc, value: anytype) !Self {
    const val_as_bytes = switch (@typeInfo(@TypeOf(value))) {
        .pointer => std.mem.sliceAsBytes(value),
        else => std.mem.asBytes(&value),
    };

    if (val_as_bytes.len > size_cpu(desc.len, desc.typ)) {
        std.debug.print("Value as bytes length {d} exceeds expected size {d} (type {s} * len {d})\n", .{
            val_as_bytes.len,
            size_cpu(desc.len, desc.typ),
            @tagName(desc.typ),
            desc.len,
        });
        return error.InvalidLengthTypeForParamValue;
    }

    const bytes = try allocator.alloc(u8, size_cpu(desc.len, desc.typ));
    @memset(bytes, 0); // zero out the bytes to avoid uninitialized data issues

    // std.debug.print("Initializing param {s} with value of type {s} at {*} {d}\n", .{ desc.name, @tagName(desc.typ), bytes, val_as_bytes.len });
    @memcpy(bytes[0..val_as_bytes.len], val_as_bytes);

    const self = Self{
        .desc = desc,
        .bytes = bytes, // store the pointer to the allocated space
    };
    return self;
}
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.bytes);
}

pub fn set(self: *Self, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        // some checks for slices
        .pointer => {
            const slice_info = @typeInfo(@TypeOf(value)).pointer;
            if (value.len > self.desc.len) {
                std.debug.print("Value slice length {d} exceeds expected length {d} for param {s}\n", .{
                    value.len,
                    self.desc.len,
                    self.desc.name,
                });
                return error.InvalidLengthTypeForParamValue;
            }
            if (slice_info.child != u8) {
                std.debug.print("Expected array of u8 for param {s}, but got array of {s}\n", .{
                    self.desc.name,
                    @typeName(slice_info.child),
                });
                return error.InvalidTypeForParamValue;
            }
        },
        else => {},
    }

    // convert value to bytes
    const val_as_bytes = switch (@typeInfo(@TypeOf(value))) {
        .pointer => std.mem.sliceAsBytes(value),
        else => std.mem.asBytes(&value),
    };
    // copy bytes to self.bytes
    @memcpy(self.bytes[0..val_as_bytes.len], val_as_bytes);
}

pub fn get(self: Self, T: type) T {
    return switch (@typeInfo(T)) {
        .pointer => std.mem.sliceTo(std.mem.bytesAsSlice(u8, self.bytes), 0),
        else => std.mem.bytesToValue(T, self.bytes),
    };
}

pub fn size_cpu(len: u32, typ: ParamValueTag) usize {
    return switch (typ) {
        .i32 => @sizeOf(i32) * len,
        .f32 => @sizeOf(f32) * len,
        .str => @sizeOf(u8) * len,
        // else => unreachable,
    };
}

// ================
// GPU related functions, which will be used to write the param data to a GPU buffer
// ================

pub fn size(self: Self) usize {
    return switch (self.desc.typ) {
        .i32 => switch (self.desc.len) {
            1 => gpu_data.size(i32),
            // 2 => gpu_data.size([2]i32)
            else => unreachable,
        },
        .f32 => switch (self.desc.len) {
            1 => gpu_data.size(f32),
            else => unreachable,
        },
        else => unreachable,
    };
}

pub fn alignment(self: Self) usize {
    return switch (self.desc.typ) {
        .i32 => switch (self.desc.len) {
            1 => gpu_data.alignment(i32),
            else => unreachable,
        },
        .f32 => switch (self.desc.len) {
            1 => gpu_data.alignment(f32),
            else => unreachable,
        },
        else => unreachable,
    };
}

pub fn writeBytes(self: Self, buf: []u8) void {
    switch (self.desc.typ) {
        .i32 => {
            @memcpy(buf[0..self.bytes.len], self.bytes);
        },
        .f32 => {
            @memcpy(buf[0..self.bytes.len], self.bytes);
        },
        // writing strings to gpu are not supported
        else => unreachable,
    }
}

pub fn layoutTaggedUnion(maybe_buf: ?[]u8, tu: []Self) !usize {
    var i: usize = 0;
    if (tu.len == 0) {
        return 0;
    }

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
        try Self.init(allocator, .{ .name = "a", .len = 1, .typ = .f32 }, @as(f32, 3.14)),
        try Self.init(allocator, .{ .name = "b", .len = 1, .typ = .i32 }, @as(i32, 42)),
        try Self.init(allocator, .{ .name = "c", .len = 1, .typ = .f32 }, @as(f32, 2.718)),
    };
    defer for (&tu) |*param| param.deinit(allocator);

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

test "layoutTaggedUnion null arr" {
    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    const tua = [4]?Self{
        try Self.init(allocator, .{ .name = "a", .len = 1, .typ = .f32 }, @as(f32, 3.14)),
        try Self.init(allocator, .{ .name = "b", .len = 1, .typ = .i32 }, @as(i32, 42)),
        try Self.init(allocator, .{ .name = "c", .len = 1, .typ = .f32 }, @as(f32, 2.718)),
        null,
    };
    defer for (&tua) |*maybe_param_ptr| {
        var maybe_param = maybe_param_ptr.*;
        if (maybe_param) |*param| {
            param.deinit(allocator);
        }
    };

    var tu: [16]Self = undefined;
    var len: u32 = 0;
    for (tua, 0..) |maybe_p, i| {
        if (maybe_p) |p| {
            tu[i] = p;
            len = len + 1;
        }
    }

    const used_len = try layoutTaggedUnion(buf, tu[0..len]);
    const bytes_buf = buf[0..used_len];
    try std.testing.expectEqual(12, bytes_buf.len);
}

test "Param f32 get/set" {
    const allocator = std.testing.allocator;
    const Param = @This();
    var param = try Param.init(
        allocator,
        .{ .name = "test_param", .len = 1, .typ = .f32 },
        @as(f32, 3.14),
    );
    defer param.deinit(allocator);

    const val = param.get(f32);
    try std.testing.expect(val == @as(f32, 3.14));

    try param.set(@as(f32, 2.718));
    const val2 = param.get(f32);
    try std.testing.expect(val2 == @as(f32, 2.718));
}

test "Param [2]f32 get/set" {
    const allocator = std.testing.allocator;
    const Param = @This();
    var param = try Param.init(
        allocator,
        .{ .name = "test_param", .len = 2, .typ = .f32 },
        @as([2]f32, .{ 3.14, 2.718 }),
    );
    defer param.deinit(allocator);

    const val = param.get([2]f32);
    try std.testing.expectEqual(val, @as([2]f32, .{ 3.14, 2.718 }));

    try param.set(@as([2]f32, .{ 2.718, 1.618 }));
    const val2 = param.get([2]f32);
    try std.testing.expectEqual(val2, @as([2]f32, .{ 2.718, 1.618 }));

    try param.set(@as([2]f32, .{ 1.0, 2.0 }));
    const val3 = param.get([2]f32);
    try std.testing.expectEqual(val3, @as([2]f32, .{ 1.0, 2.0 }));
}

test "Param module init string" {
    const allocator = std.testing.allocator;
    const Param = @This();
    var param = try Param.init(
        allocator,
        .{ .name = "test_param", .len = 256, .typ = .str },
        @as([]const u8, "asdf"),
    );
    defer param.deinit(allocator);

    const val = param.get([]const u8);
    try std.testing.expectEqualStrings(@as([]const u8, "asdf"), val);

    try param.set(@as([]const u8, "qwer"));

    const val2 = param.get([]const u8);
    try std.testing.expectEqualStrings(@as([]const u8, "qwer"), val2);
}
