const std = @import("std");
const HistList = @import("histlist.zig").HistList;
const HistoryConfig = @import("histlist.zig").HistoryConfig;
const pipeline = @import("pipeline.zig");
const Pipeline = pipeline.Pipeline;
const OperationError = pipeline.OperationError;
const ModuleHandle = pipeline.ModuleHandle;
const Module = @import("Module.zig");
const serdes = @import("serdes.zig");
const colonconfig = @import("colonconfig");

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
        const all = self.histlist.all();
        const end = @min(target_clamped, all.len);
        for (all[0..end]) |item| {
            try serdes.deserialize(pipe, std.Io.Reader.fixed(item.line));
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

    /// Delta construction may fail on the writer (OOM) or on unknown
    /// module/param handles; all of it is a failed recording.
    fn recordError(err: anyerror) OperationError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.RecorderFailed,
        };
    }

    pub fn recordParamDelta(self: *Self, mod_handle: ModuleHandle, param_name: []const u8) OperationError!void {
        const pipe = super(self);
        const mod = try pipe.module_pool.getPtr(mod_handle);
        const idx = mod.getParamIndex(param_name) catch return error.RecorderFailed;
        const param = mod.params[idx] orelse return error.RecorderFailed;

        const line = self.histlist.beginLine();
        serdes.PresetConfig.writeRecord(line, .{ .param = .{
            .name = mod.name,
            .id = mod.id,
            .param = param.desc.name,
            .value = serdes.schemaValue(param.value()),
        } }) catch return error.RecorderFailed;
        // the key prefixes the value so repeated edits of the same param coalesce
        self.histlist.keyWriter().print("{s}:{s}:{s}:{s}", .{ @tagName(.param), mod.name, mod.id, param.desc.name }) catch return error.RecorderFailed;
        self.histlist.commit(self.config) catch |err| return recordError(err);
    }

    pub fn recordModuleDelta(self: *Self, name: []const u8, id: []const u8) OperationError!void {
        const line = self.histlist.beginLine();
        serdes.PresetConfig.writeRecord(line, .{ .module = .{ .name = name, .id = id } }) catch return error.RecorderFailed;
        self.histlist.commit(self.config) catch |err| return recordError(err);
    }

    pub fn recordRemoveDelta(self: *Self, name: []const u8, id: []const u8) OperationError!void {
        const line = self.histlist.beginLine();
        serdes.PresetConfig.writeRecord(line, .{ .removemodule = .{ .name = name, .id = id } }) catch return error.RecorderFailed;
        self.histlist.commit(self.config) catch |err| return recordError(err);
    }

    pub fn recordConnectDelta(
        self: *Self,
        src_mod: ModuleHandle,
        src_mod_socket_name: []const u8,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) OperationError!void {
        const pipe = super(self);
        const src = try pipe.module_pool.getPtr(src_mod);
        const dst = try pipe.module_pool.getPtr(dst_mod);

        const line = self.histlist.beginLine();
        serdes.PresetConfig.writeRecord(line, .{ .connect = .{
            .src = src.name,
            .src_id = src.id,
            .src_sock = src_mod_socket_name,
            .dst = dst.name,
            .dst_id = dst.id,
            .dst_sock = dst_mod_socket_name,
        } }) catch return error.RecorderFailed;
        self.histlist.keyWriter().print("{s}:{s}:{s}:{s}", .{ @tagName(.connect), dst.name, dst.id, dst_mod_socket_name }) catch return error.RecorderFailed;
        self.histlist.commit(self.config) catch |err| return recordError(err);
    }

    pub fn recordDisconnectDelta(
        self: *Self,
        dst_mod: ModuleHandle,
        dst_mod_socket_name: []const u8,
    ) OperationError!void {
        const pipe = super(self);
        const dst = try pipe.module_pool.getPtr(dst_mod);

        const line = self.histlist.beginLine();
        // `-1` as source type encodes an explicit disconnect
        serdes.PresetConfig.writeRecord(line, .{ .connect = .{
            .src = "-1",
            .src_id = "",
            .src_sock = "",
            .dst = dst.name,
            .dst_id = dst.id,
            .dst_sock = dst_mod_socket_name,
        } }) catch return error.RecorderFailed;
        self.histlist.keyWriter().print("{s}:{s}:{s}:{s}", .{ @tagName(.connect), dst.name, dst.id, dst_mod_socket_name }) catch return error.RecorderFailed;
        self.histlist.commit(self.config) catch |err| return recordError(err);
    }

    // ================================================
    // History save/load
    // ================================================

    /// Serialize the committed steps only — the redo tail past the cursor is
    /// discarded — as one `serdes` grammar line per step.
    pub fn save(self: *Self, writer: *std.Io.Writer) OperationError!void {
        for (self.histlist.committed()) |item| {
            writer.writeAll(item.line) catch return error.RecorderFailed;
            writer.writeByte('\n') catch return error.RecorderFailed;
        }
    }

    /// Replace the log with the lines written by `save` and rebuild the
    /// pipeline state by replaying every loaded step (all become committed).
    pub fn load(self: *Self, reader: std.Io.Reader) OperationError!void {
        self.histlist.clear();

        var lit: colonconfig.LineIterator = .init(reader);
        while (lit.next() catch unreachable) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            try self.histlist.append(line);
        }

        try self.replayHistory(self.histlist.count());
    }
};
