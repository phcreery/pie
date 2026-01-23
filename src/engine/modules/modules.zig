pub const i_raw = @import("i-raw/module.zig");
pub const format = @import("format/module.zig");
pub const demosaic = @import("demosaic/module.zig");
pub const o_png = @import("o-png/module.zig");

pub const test_multiply = @import("test-multiply/module.zig");
pub const test_2nodes = @import("test-2nodes/module.zig");
pub const test_i_1234 = @import("test-i-1234/module.zig");
pub const test_o_2468 = @import("test-o-2468/module.zig");
pub const test_o_firstbytes = @import("test-o-firstbytes/module.zig");
pub const test_nop = @import("test-nop/module.zig");

const std = @import("std");
const api = @import("api.zig");

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

    pub fn addModule(self: *Self, desc: api.ModuleDesc) !void {
        try self.map.put(desc.name, desc);
    }

    pub fn get(self: *Self, name: []const u8) ?api.ModuleDesc {
        return self.map.get(name).?;
    }
};

pub fn populateRegistry(registry: *Registry) !void {
    // add built-in modules
    try registry.addModule(i_raw.module);
    try registry.addModule(format.module);
    try registry.addModule(demosaic.module);
    try registry.addModule(o_png.module);
    // add test modules
    try registry.addModule(test_multiply.module);
    try registry.addModule(test_2nodes.module);
    try registry.addModule(test_i_1234.module);
    try registry.addModule(test_o_2468.module);
    try registry.addModule(test_o_firstbytes.module);
    try registry.addModule(test_nop.module);
}
