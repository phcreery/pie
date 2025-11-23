const std = @import("std");
const api = @import("modules/api.zig");
const Module = @import("Module.zig");
const gpu = @import("gpu.zig");
const pipeline = @import("pipeline.zig");
const slog = std.log.scoped(.param);

pub const ParamType = enum {
    integer,
    float,
    boolean,
    // string,

    pub fn size(self: ParamType) usize {
        return switch (self) {
            .integer => @sizeOf(i64),
            .float => @sizeOf(f64),
            .boolean => @sizeOf(bool),
            // .string => @sizeOf([]const u8),
        };
    }
};
pub const ParamTypeValue = union(ParamType) {
    integer: i64,
    float: f64,
    boolean: bool,
    // string: []const u8,
};

name: api.NodeDesc,
param_type: ParamType,
param_value: ParamTypeValue,

const Self = @This();

pub fn init(
    name: []const u8,
    param_type: ParamType,
    param_value: ParamTypeValue,
) !Self {
    return Self{
        .name = name,
        .param_type = param_type,
        .param_value = param_value,
    };
}
