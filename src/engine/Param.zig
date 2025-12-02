const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.param);

// see: https://github.com/greggman/webgpu-utils/blob/3f1a4561622ea53e160b91de0d2a196443722dfd/src/wgsl-types.ts#L22

pub const ParamValueTag = enum {
    i32,
    f32,
    // bool,
    // string,
};
pub const ParamValue = union(ParamValueTag) {
    i32: i32,
    f32: f32,
    // bool: bool,
    // string: []const u8,

    pub fn size(self: ParamValue) usize {
        return switch (self) {
            .i32 => @sizeOf(i32),
            .f32 => @sizeOf(f32),
            // .bool => @sizeOf(bool),
            // .string => @sizeOf([]const u8),
        };
    }

    /// Get the WebGPU alignment requirement of this ParamValue type
    /// https://webgpufundamentals.org/webgpu/lessons/webgpu-memory-layout.html
    pub fn alignment(self: ParamValue) usize {
        return switch (self) {
            .i32 => 4,
            .f32 => 4,
            // .bool => 1,
            // .string => @alignOf([]const u8),
        };
    }

    pub fn asBytes(self: *const ParamValue) []u8 {
        return switch (self.*) {
            // .i32 => @ptrCast(@alignCast(@constCast(&self.i32))), // or std.mem.asBytes()
            .i32 => std.mem.asBytes(@constCast(&self.i32)),
            .f32 => @ptrCast(@alignCast(@constCast(&self.f32))),
            // .bool => std.mem.asBytes(&self.bool),
            // .string => std.mem.asBytes(&self.string),
        };
    }
};

name: []const u8,
value: ParamValue,

const Self = @This();

pub fn init(name: []const u8, value: ParamValue) Self {
    return Self{
        .name = name,
        .value = value,
    };
}

test "Param module init" {
    const Param = @This();
    const param = Param.init("test_param", .{ .f32 = 3.14 });
    // slog.info("Param initialized: {s}, value: {any}", .{ param.name, param.value });

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
    const param: Param = .{ .name = "test_param", .value = .{ .i32 = 314 } };
    // slog.info("Param initialized: {s}, value: {any}", .{ param.name, param.value });
    slog.info("Param value size: {any}", .{param.value.size()});

    switch (param.value) {
        .i32 => |v| {
            try std.testing.expect(v == 314);
        },
        else => {
            try std.testing.expect(false);
        },
    }
}
