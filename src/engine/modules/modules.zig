const std = @import("std");
const api = @import("api.zig");

pub const i_raw = @import("i-raw/module.zig");
pub const format = @import("format/module.zig");
pub const denoise = @import("denoise/module.zig");
pub const demosaic = @import("demosaic/module.zig");
pub const color = @import("color/module.zig");
pub const o_png = @import("o-png/module.zig");
pub const o_ppm = @import("o-ppm/module.zig");

pub const test_multiply = @import("test-multiply/module.zig");
pub const test_2nodes = @import("test-2nodes/module.zig");
pub const test_i_1234 = @import("test-i-1234/module.zig");
pub const test_o_2468 = @import("test-o-2468/module.zig");
pub const test_o_firstbytes = @import("test-o-firstbytes/module.zig");
pub const test_nop = @import("test-nop/module.zig");

pub fn populateRegistry(registry: *Registry) !void {
    // add built-in modules
    try registry.add(i_raw.desc);
    try registry.add(format.desc);
    try registry.add(denoise.desc);
    try registry.add(demosaic.desc);
    try registry.add(color.desc);
    try registry.add(o_png.desc);
    try registry.add(o_ppm.desc);

    // add test modules
    try registry.add(test_multiply.desc);
    // try registry.add(test_2nodes.desc);
    try registry.add(test_i_1234.desc);
    try registry.add(test_o_2468.desc);
    // try registry.add(test_o_firstbytes.desc);
    // try registry.add(test_nop.desc);
}

pub const Registry = struct {
    map: std.StringHashMap(api.ModuleDesc),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var reg: Self = .{
            .map = std.StringHashMap(api.ModuleDesc).init(allocator),
        };
        try populateRegistry(&reg);
        return reg;
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
