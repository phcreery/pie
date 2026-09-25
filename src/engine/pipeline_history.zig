const std = @import("std");
const HistList = @import("histlist.zig").HistList;
const HistoryConfig = @import("histlist.zig").HistoryConfig;
const pipeline = @import("pipeline.zig");
const Pipeline = pipeline.Pipeline;
const ModuleHandle = pipeline.ModuleHandle;
const serdes = @import("serdes.zig");

pub const PipelineHistory = struct {
    histlist: HistList([]const u8, []const u8),
    config: HistoryConfig,

    fn super(field_ptr: *@This()) *Pipeline {
        return @alignCast(@fieldParentPtr("history", field_ptr));
    }
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .histlist = HistList([]const u8, []const u8).init(allocator, io),
            .config = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.histlist.deinit();
        self.* = undefined;
    }

    // ================================================
    // History undo / redo / rollback
    // ================================================

    /// Roll back to the given committed step (exclusive index). Reconstructs the
    /// graph from scratch by replaying every recorded delta up to `target`
    /// onto a cleared pipeline — the same model vkdt uses. Module names resolve
    /// against the registered repos. `history.setCursor(end)` mirrors the target.
    pub fn replayHistory(self: *Self, target: usize) !void {
        const pipe = super(self);
        const target_clamped = @min(target, self.histlist.count());

        // tear down the live graph
        pipe.clear();

        // replay committed deltas over the empty graph
        var scratch = std.heap.ArenaAllocator.init(pipe.allocator);
        defer scratch.deinit();
        const all = self.histlist.all();
        const end = @min(target_clamped, all.len);
        for (all[0..end], 0..) |item, i| {
            try serdes.apply(pipe, scratch.allocator(), item.line, i);
        }

        self.histlist.setCursor(end);
    }

    /// Undo one edit step and apply it to the live pipeline.
    pub fn undo(self: *Self) !void {
        // const pipe = super(self);
        if (!self.histlist.canUndo()) return;
        try self.replayHistory(self.histlist.cursor - 1);
    }

    /// Redo one edit step and apply it to the live pipeline.
    pub fn redo(self: *Self) !void {
        // const pipe = super(self);
        if (!self.histlist.canRedo()) return;
        try self.replayHistory(self.histlist.cursor + 1);
    }

    // ================================================
    // History delta recorders
    // ================================================

    pub fn recordParamDelta(self: *Self, allocator: std.mem.Allocator, mod_handle: ModuleHandle, param_name: []const u8) !void {
        const pipe = super(self);
        const mod = try pipe.module_pool.getPtr(mod_handle);
        const line = try serdes.paramToLine(pipe, mod_handle, param_name);
        defer allocator.free(line);
        // key prefixes the value so repeated edits of the same param coalesce
        const key = try std.mem.concat(allocator, u8, &.{ "param:", mod.name, ":", mod.id, ":", param_name });
        defer allocator.free(key);
        try self.histlist.appendKeyed(line, key, self.config);
    }

    pub fn recordModuleDelta(self: *Self, allocator: std.mem.Allocator, name: []const u8, id: []const u8) !void {
        // const pipe = super(self);
        const buf = try std.mem.concat(allocator, u8, &.{ "module:", name, ":", id });
        defer allocator.free(buf);
        try self.histlist.append(buf);
    }

    pub fn recordRemoveDelta(self: *Self, allocator: std.mem.Allocator, name: []const u8, id: []const u8) !void {
        // const pipe = super(self);
        const buf = try std.mem.concat(allocator, u8, &.{ "removemodule:", name, ":", id });
        defer allocator.free(buf);
        try self.histlist.append(buf);
    }

    pub fn recordConnectDelta(
        self: *Self,
        allocator: std.mem.Allocator,
        src_mod: ModuleHandle,
        src_mod_socket_name: []const u8,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        const pipe = super(self);
        const src = try pipe.module_pool.getPtr(src_mod);
        const dst = try pipe.module_pool.getPtr(dst_mod);
        const buf = try std.mem.concat(allocator, u8, &.{
            "connect:",    src.name, ":",    src.id, ":",                 src_mod_socket_name, ":",
            dst.name, ":",           dst.id, ":",    dst_mod_socket_name,
        });
        defer allocator.free(buf);
        const key = try std.mem.concat(allocator, u8, &.{ "connect:", dst.name, ":", dst.id, ":", dst_mod_socket_name });
        defer allocator.free(key);
        try self.histlist.appendKeyed(buf, key, self.config);
    }

    pub fn recordDisconnectDelta(
        self: *Self,
        allocator: std.mem.Allocator,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) !void {
        const pipe = super(self);
        const dst = try pipe.module_pool.getPtr(dst_mod);
        const buf = try std.mem.concat(allocator, u8, &.{
            "connect:-1:-1:-1:", dst.name, ":", dst.id, ":", dst_mod_socket_name,
        });
        defer allocator.free(buf);
        const key = try std.mem.concat(allocator, u8, &.{ "connect:", dst.name, ":", dst.id, ":", dst_mod_socket_name });
        defer allocator.free(key);
        try self.histlist.appendKeyed(buf, key, self.config);
    }
};
