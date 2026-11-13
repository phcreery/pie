const std = @import("std");
const pipeline = @import("pipeline.zig");
const colonconfig = @import("colonconfig");
const Param = @import("Param.zig");
const slog = std.log.scoped(.serdes);

pub const PresetConfig = colonconfig.ColonConfig(Schema);

/// Record payloads: field order maps positionally onto the arguments of each
/// line. The tag names of `Schema` are the grammar keys, and each payload
/// knows how to apply itself to a pipeline.
pub const ModuleCfgEntry = struct {
    name: []const u8,
    id: []const u8,

    const Self = @This();
    fn deserialize(self: Self, line_no: usize, pipe: *pipeline.Pipeline) !void {
        if (self.name.len == 0 or self.id.len == 0) {
            slog.warn("line {d}: incomplete module line, skipping", .{line_no});
            return;
        }
        const fullname = try std.mem.concat(pipe.allocator, u8, &.{ self.name, ":", self.id });
        defer pipe.allocator.free(fullname);
        if (pipe.module_name_map.contains(fullname)) return; // dedup
        if (pipe.repo.get(self.name) == null) {
            slog.warn("line {d}: unknown module '{s}', skipping", .{ line_no, self.name });
            return;
        }
        _ = try pipe.addModuleNoRecord(self.name, self.id);
    }
};

pub const ConnectCfgEntry = struct {
    src: []const u8,
    src_id: []const u8,
    src_sock: []const u8,
    dst: []const u8,
    dst_id: []const u8,
    dst_sock: []const u8,

    const Self = @This();
    fn deserialize(self: Self, line_no: usize, pipe: *pipeline.Pipeline) !void {
        if (self.dst.len == 0 or self.dst_id.len == 0 or self.dst_sock.len == 0) {
            slog.warn("line {d}: incomplete connect line, skipping", .{line_no});
            return;
        }
        // A `-1` source encodes an explicit disconnect
        if (std.mem.eql(u8, self.src, "-1")) {
            pipe.disconnectModuleByNameNoRecord(self.dst, self.dst_id, self.dst_sock) catch |err| {
                slog.warn("line {d}: disconnect failed ({}), skipping", .{ line_no, err });
            };
            return;
        }
        if (self.src.len == 0 or self.src_id.len == 0 or self.src_sock.len == 0) {
            slog.warn("line {d}: incomplete connect line, skipping", .{line_no});
            return;
        }
        pipe.connectModulesByNameNoRecord(self.src, self.src_id, self.src_sock, self.dst, self.dst_id, self.dst_sock) catch |err| {
            slog.warn("line {d}: connect failed ({}), skipping", .{ line_no, err });
        };
    }
};

pub const ParamCfgEntry = struct {
    name: []const u8,
    id: []const u8,
    param: []const u8,
    value: colonconfig.Value,
    pub const idx_map = .{ 0, 1, 2, colonconfig.rest };

    const Self = @This();
    fn deserialize(self: Self, line_no: usize, pipe: *pipeline.Pipeline) !void {
        if (self.name.len == 0 or self.id.len == 0 or self.param.len == 0) {
            slog.warn("line {d}: incomplete param line, skipping", .{line_no});
            return;
        }
        const value_text = switch (self.value) {
            .text => |s| s,
            else => {
                slog.warn("line {d}: param value must be text, skipping", .{line_no});
                return;
            },
        };

        const fullname = try std.mem.concat(pipe.allocator, u8, &.{ self.name, ":", self.id });
        defer pipe.allocator.free(fullname);
        const mod_handle = pipe.module_name_map.get(fullname) orelse {
            slog.warn("line {d}: unknown module '{s}', skipping", .{ line_no, fullname });
            return;
        };
        const mod = try pipe.module_pool.getPtr(mod_handle);
        const idx = mod.getParamIndex(self.param) catch {
            slog.warn("line {d}: unknown parameter '{s}', skipping", .{ line_no, self.param });
            return;
        };
        const param = if (mod.params[idx]) |*p| p else {
            slog.warn("line {d}: unknown parameter '{s}', skipping", .{ line_no, self.param });
            return;
        };
        const pdesc = param.desc;
        switch (pdesc.typ) {
            .f32 => {
                const values = std.mem.bytesAsSlice(f32, param.bytes);
                var value_tokens = std.mem.splitScalar(u8, value_text, ':');
                for (values) |*value| {
                    const tok = value_tokens.next() orelse "";
                    value.* = if (tok.len == 0) 0 else std.fmt.parseFloat(f32, tok) catch {
                        slog.warn("line {d}: unparseable f32 '{s}', skipping", .{ line_no, tok });
                        return;
                    };
                }
            },
            .i32 => {
                const values = std.mem.bytesAsSlice(i32, param.bytes);
                var value_tokens = std.mem.splitScalar(u8, value_text, ':');
                for (values) |*value| {
                    const tok = value_tokens.next() orelse "";
                    value.* = if (tok.len == 0) 0 else std.fmt.parseInt(i32, tok, 10) catch {
                        slog.warn("line {d}: unparseable i32 '{s}', skipping", .{ line_no, tok });
                        return;
                    };
                }
            },
            .str => {
                if (value_text.len >= pdesc.len) {
                    slog.warn("line {d}: string value too long for param '{s}', skipping", .{ line_no, pdesc.name });
                    return;
                }
                @memset(param.bytes, 0); // clear stale tail so string reads stop at the NUL
                param.set(value_text) catch {
                    slog.warn("line {d}: failed to set string param '{s}', skipping", .{ line_no, pdesc.name });
                    return;
                };
            },
            .@"enum" => {
                const values = std.mem.bytesAsSlice(u32, param.bytes);
                var value_tokens = std.mem.splitScalar(u8, value_text, ':');
                for (values) |*value| {
                    const tok = value_tokens.next() orelse "";
                    value.* = if (tok.len == 0) 0 else std.fmt.parseInt(u32, tok, 10) catch {
                        slog.warn("line {d}: unparseable enum '{s}', skipping", .{ line_no, tok });
                        return;
                    };
                }
            },
        }
    }
};

pub const RemoveModuleCfgEntry = struct {
    name: []const u8,
    id: []const u8,

    const Self = @This();
    fn deserialize(self: Self, line_no: usize, pipe: *pipeline.Pipeline) !void {
        if (self.name.len == 0 or self.id.len == 0) {
            slog.warn("line {d}: incomplete removemodule line, skipping", .{line_no});
            return;
        }
        pipe.removeModuleByName(self.name, self.id) catch |err| {
            slog.warn("line {d}: removemodule failed ({}), skipping", .{ line_no, err });
        };
    }
};

/// Every record the grammar understands; tag names are the grammar keys.
pub const Schema = union(enum) {
    module: ModuleCfgEntry,
    connect: ConnectCfgEntry,
    param: ParamCfgEntry,
    removemodule: RemoveModuleCfgEntry,
};

/// Adapt a live param value to the schema's write representation.
pub fn schemaValue(value: Param.Value) colonconfig.Value {
    return switch (value) {
        .i32 => |xs| .{ .i32 = xs },
        .f32 => |xs| .{ .f32 = xs },
        .str => |s| .{ .text = s },
        .@"enum" => |xs| .{ .@"enum" = xs },
    };
}

/// This function serializes the current state of the pipeline into a colonconfig format.
/// It should only ever be used for history compression.
pub fn serialize(pipe: *pipeline.Pipeline, writer: *std.Io.Writer) !void {
    // modules
    var it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        try PresetConfig.writeEntry(writer, .{ .module = .{ .name = mod.name, .id = mod.id } });
    }

    // connects: one line per edge, from the destination side, input sockets only
    it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        for (mod.sockets) |maybe_sock| {
            const sock = maybe_sock orelse continue;
            if (sock.type.direction() != .input) continue;
            const conn = sock.connected_to_module orelse continue;
            const src_mod = try pipe.module_pool.getPtr(conn.item);
            const src_sock = src_mod.sockets[conn.socket_idx] orelse continue;
            try PresetConfig.writeEntry(writer, .{ .connect = .{
                .src = src_mod.name,
                .src_id = src_mod.id,
                .src_sock = src_sock.name,
                .dst = mod.name,
                .dst_id = mod.id,
                .dst_sock = sock.name,
            } });
        }
    }

    // params: one line per declared param
    it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        for (mod.params) |maybe_param| {
            const param = maybe_param orelse continue;
            try PresetConfig.writeEntry(writer, .{ .param = .{
                .name = mod.name,
                .id = mod.id,
                .param = param.desc.name,
                .value = schemaValue(param.value()),
            } });
        }
    }
}

/// This function deserializes the colonconfig-formatted text into the pipeline state.
/// It should only ever be used for history replay as it does not record any new history.
pub fn deserialize(pipe: *pipeline.Pipeline, reader: std.Io.Reader) !void {
    var it = PresetConfig.EntryIterator.init(reader);
    while (it.next() catch unreachable) |entry| {
        switch (entry) {
            .connect => |cfg| try cfg.deserialize(it.line_no, pipe),
            .param => |cfg| try cfg.deserialize(it.line_no, pipe),
            .module => |cfg| try cfg.deserialize(it.line_no, pipe),
            .removemodule => |cfg| try cfg.deserialize(it.line_no, pipe),
        }
    }
}
