const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const gpu_data = @import("gpu_data.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.param);

pub const ParamValueTag = gpu_data.ParamValueTag;
pub const ParamValue = gpu_data.ParamValue;

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
