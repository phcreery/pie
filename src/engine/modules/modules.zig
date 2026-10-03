const std = @import("std");
const api = @import("api.zig");

pub fn populateRepository(repo: *Repository) !void {
    // built-in modules
    try repo.add(@import("i-raw/module.zig").def);
    try repo.add(@import("i-png/module.zig").def);
    try repo.add(@import("format/module.zig").def);
    try repo.add(@import("denoise/module.zig").def);
    try repo.add(@import("whitebalance/module.zig").def);
    try repo.add(@import("demosaic/module.zig").def);
    try repo.add(@import("crop/module.zig").def);
    try repo.add(@import("color/module.zig").def);
    try repo.add(@import("filmcurv/module.zig").def);
    try repo.add(@import("downscale/module.zig").def);
    try repo.add(@import("o-png/module.zig").def);
    try repo.add(@import("o-qoi/module.zig").def);
    try repo.add(@import("o-ppm/module.zig").def);
    try repo.add(@import("o-display/module.zig").def);

    // test modules
    try repo.add(@import("test-multiply/module.zig").def);
    try repo.add(@import("test-2nodes/module.zig").def);
    try repo.add(@import("test-i-1234/module.zig").def);
    try repo.add(@import("test-o-2468/module.zig").def);
    // try repository.add(@import("test-o-firstbytes/module.zig").def);
    // try repo.add(@import("test-nop-wgsl/module.zig").def);
    try repo.add(@import("test-nop-glsl/module.zig").def);
    try repo.add(@import("test-swap-roi/module.zig").def);
    try repo.add(@import("test-nop-zig/module.zig").def);
    // try repo.add(@import("test-text/module.zig").def);
}

pub const Repository = struct {
    map: std.StringHashMap(api.ModuleDef),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var repo: Self = .{
            .map = std.StringHashMap(api.ModuleDef).init(allocator),
        };
        try populateRepository(&repo);
        return repo;
    }
    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn add(self: *Self, def: api.ModuleDef) !void {
        try self.map.put(def.desc.name, def);
    }

    pub fn get(self: *Self, name: []const u8) ?api.ModuleDef {
        return self.map.get(name);
    }
};
