const std = @import("std");
const api = @import("api.zig");

pub fn populateRegistry(registry: *Registry) !void {
    // add built-in modules
    try registry.add(@import("i-raw/module.zig").desc);
    try registry.add(@import("format/module.zig").desc);
    try registry.add(@import("denoise/module.zig").desc);
    try registry.add(@import("whitebalance/module.zig").desc);
    try registry.add(@import("demosaic/module.zig").desc);
    try registry.add(@import("crop/module.zig").desc);
    try registry.add(@import("color/module.zig").desc);
    try registry.add(@import("filmcurv/module.zig").desc);
    try registry.add(@import("o-png/module.zig").desc);
    try registry.add(@import("o-ppm/module.zig").desc);

    // add test modules
    try registry.add(@import("test-multiply/module.zig").desc);
    // try registry.add(@import("test-2nodes/module.zig").desc);
    try registry.add(@import("test-i-1234/module.zig").desc);
    try registry.add(@import("test-o-2468/module.zig").desc);
    // try registry.add(@import("test-o-firstbytes/module.zig").desc);
    try registry.add(@import("test-nop/module.zig").desc);
    try registry.add(@import("test-nop-glsl/module.zig").desc);
    try registry.add(@import("test-nop-zig/module.zig").desc);
    try registry.add(@import("test-text/module.zig").desc);
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
