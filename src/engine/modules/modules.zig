const std = @import("std");
const api = @import("api.zig");

pub fn populateRepository(repository: *Repository) !void {
    // built-in modules
    try repository.add(@import("i-raw/module.zig").desc);
    try repository.add(@import("format/module.zig").desc);
    try repository.add(@import("denoise/module.zig").desc);
    try repository.add(@import("whitebalance/module.zig").desc);
    try repository.add(@import("demosaic/module.zig").desc);
    try repository.add(@import("crop/module.zig").desc);
    try repository.add(@import("color/module.zig").desc);
    try repository.add(@import("filmcurv/module.zig").desc);
    try repository.add(@import("o-png/module.zig").desc);
    try repository.add(@import("o-ppm/module.zig").desc);
    try repository.add(@import("o-display/module.zig").desc);

    // test modules
    try repository.add(@import("test-multiply/module.zig").desc);
    // try repository.add(@import("test-2nodes/module.zig").desc);
    try repository.add(@import("test-i-1234/module.zig").desc);
    try repository.add(@import("test-o-2468/module.zig").desc);
    // try repository.add(@import("test-o-firstbytes/module.zig").desc);
    try repository.add(@import("test-nop/module.zig").desc);
    try repository.add(@import("test-nop-glsl/module.zig").desc);
    // try repository.add(@import("test-nop-zig/module.zig").desc);
    try repository.add(@import("test-text/module.zig").desc);
}

pub const Repository = struct {
    map: std.StringHashMap(api.ModuleDesc),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var repo: Self = .{
            .map = std.StringHashMap(api.ModuleDesc).init(allocator),
        };
        try populateRepository(&repo);
        return repo;
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
