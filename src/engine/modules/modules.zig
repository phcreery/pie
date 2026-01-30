const std = @import("std");
const api = @import("api.zig");

pub const i_raw = @import("i-raw/module.zig");
pub const format = @import("format/module.zig");
pub const denoise = @import("denoise/module.zig");
pub const demosaic = @import("demosaic/module.zig");
pub const color = @import("color/module.zig");
pub const o_png = @import("o-png/module.zig");

pub const test_multiply = @import("test-multiply/module.zig");
pub const test_2nodes = @import("test-2nodes/module.zig");
pub const test_i_1234 = @import("test-i-1234/module.zig");
pub const test_o_2468 = @import("test-o-2468/module.zig");
pub const test_o_firstbytes = @import("test-o-firstbytes/module.zig");
pub const test_nop = @import("test-nop/module.zig");

pub fn populateRegistry(registry: *Registry) !void {
    // add built-in modules
    try registry.add(i_raw.module);
    try registry.add(format.module);
    try registry.add(denoise.module);
    try registry.add(demosaic.module);
    try registry.add(color.module);
    try registry.add(o_png.module);
    // add test modules
    try registry.add(test_multiply.module);
    try registry.add(test_2nodes.module);
    try registry.add(test_i_1234.module);
    try registry.add(test_o_2468.module);
    try registry.add(test_o_firstbytes.module);
    try registry.add(test_nop.module);
}

pub const Registry = struct {
    map: std.StringHashMap(api.ModuleDesc),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .map = std.StringHashMap(api.ModuleDesc).init(allocator),
        };
    }
    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn add(self: *Self, desc: api.ModuleDesc) !void {
        try self.map.put(desc.name, desc);
    }

    pub fn get(self: *Self, name: []const u8) ?api.ModuleDesc {
        return self.map.get(name).?;
    }
};
