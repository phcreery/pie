const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const gpu_data = @import("gpu_data.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.param);

name: []const u8,
value: ParamValue,

const Self = @This();

pub const ParamValueTag = gpu_data.ParamValueTag;
pub const ParamValue = gpu_data.ParamValue;

// pub const ParamValueTag = enum {
//     i32,
//     f32,
//     // bool,
//     // string,
// };
// pub const ParamValue = union(ParamValueTag) {
//     i32: i32,
//     f32: f32,
//     // bool: bool,
//     // string: []const u8,

//     pub fn size(self: ParamValue) usize {
//         return switch (self) {
//             .i32 => @sizeOf(i32),
//             .f32 => @sizeOf(f32),
//             // .bool => @sizeOf(bool),
//             // .string => @sizeOf([]const u8),
//         };
//     }

//     /// Get the WebGPU alignment requirement of this ParamValue type
//     /// https://webgpufundamentals.org/webgpu/lessons/webgpu-memory-layout.html
//     pub fn alignment(self: ParamValue) usize {
//         return switch (self) {
//             .i32 => 4,
//             .f32 => 4,
//             // .bool => 1,
//             // .string => @alignOf([]const u8),
//         };
//     }

//     pub fn asBytes(self: *const ParamValue) []u8 {
//         return switch (self.*) {
//             // .i32 => @ptrCast(@alignCast(@constCast(&self.i32))), // or std.mem.asBytes()
//             .i32 => std.mem.asBytes(@constCast(&self.i32)),
//             .f32 => @ptrCast(@alignCast(@constCast(&self.f32))),
//             // .bool => std.mem.asBytes(&self.bool),
//             // .string => std.mem.asBytes(&self.string),
//         };
//     }

//     pub fn set(self: *ParamValue, value: ParamValue) !void {
//         if (std.meta.activeTag(self.*) != std.meta.activeTag(value)) {
//             return error.ParamTypeMismatch;
//         }
//         switch (value) {
//             .i32 => {
//                 self.* = .{ .i32 = value.i32 };
//             },
//             .f32 => {
//                 self.* = .{ .f32 = value.f32 };
//             },
//             // .bool => {
//             //     param.value = .bool(value.bool);
//             // },
//             // .string => {
//             //     param.value = .string(value.string);
//             // },
//         }
//     }
// };

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
