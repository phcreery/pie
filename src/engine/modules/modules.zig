const std = @import("std");
const api = @import("api.zig");

pub fn populateRepository(repo: *Repository) !void {
    // built-in modules
    try repo.add(@import("i-raw/module.zig").desc);
    try repo.add(@import("format/module.zig").desc);
    try repo.add(@import("denoise/module.zig").desc);
    try repo.add(@import("whitebalance/module.zig").desc);
    try repo.add(@import("demosaic/module.zig").desc);
    try repo.add(@import("crop/module.zig").desc);
    try repo.add(@import("color/module.zig").desc);
    try repo.add(@import("filmcurv/module.zig").desc);
    try repo.add(@import("o-png/module.zig").desc);
    try repo.add(@import("o-ppm/module.zig").desc);
    try repo.add(@import("o-display/module.zig").desc);

    // test modules
    try repo.add(@import("test-multiply/module.zig").desc);
    // try repository.add(@import("test-2nodes/module.zig").desc);
    try repo.add(@import("test-i-1234/module.zig").desc);
    try repo.add(@import("test-o-2468/module.zig").desc);
    // try repository.add(@import("test-o-firstbytes/module.zig").desc);
    // try repo.add(@import("test-nop/module.zig").desc);
    try repo.add(@import("test-nop-glsl/module.zig").desc);
    // try repository.add(@import("test-nop-zig/module.zig").desc);
    // try repo.add(@import("test-text/module.zig").desc);
}

// pub fn populateRepository(repo: *Repository) !void {
//     // built-in modules
//     const builtin_modules = &[_][]const u8{
//         "i-raw",
//         "format",
//         "denoise",
//         "whitebalance",
//         "demosaic",
//         "crop",
//         "color",
//         "filmcurv",
//         "o-png",
//         "o-ppm",
//         "o-display",

//         // test modules
//         "test-multiply",
//         // "test-2nodes",
//         "test-i-1234",
//         "test-o-2468",
//         // "test-o-firstbytes",
//         // "test-nop",
//         "test-nop-glsl",
//         // "test-nop-zig",
//         // "test-text",
//     };
//     inline for (builtin_modules) |module_name| {
//         try repo.add(module_name, @import(module_name ++ "/module.zig").desc);
//     }
// }

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

    pub fn add2(self: *Self, name: []const u8, desc: api.ModuleDesc) !void {
        try self.map.put(name, desc);
    }

    pub fn get(self: *Self, name: []const u8) ?api.ModuleDesc {
        return self.map.get(name).?;
    }
};
