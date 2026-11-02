//! Plaintext (de)serialization of pipeline state in the grammar: `module:`,
//! `connect:`/`feedback:`, `param:`, `removemodule:` records, `:`
//! -delimited, no whitespace trimming, `#` full-line comments.
//!
//! Parsing is built on the `colonconfig` module: one CfgEntry struct per record
//! key (fields map positionally onto the arguments; `param`'s value is the
//! whole remainder via `colonconfig.rest`, so string values may contain
//! `:`). `apply` stays line-ordered — it dispatches each line through the
//! `schema` table and warn-and-continues on anything the pipeline does not
//! understand, exactly like `deserialize` does per line.
//!
//! `serialize` writes modules, then connects (destination-side only), then
//! params. `deserialize` applies onto an existing pipeline and only
//! allocator errors propagate; module ids are owned by the pipeline (see
//! `Pipeline._addModule`), so the lines may be transient.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const colonconfig = @import("colonconfig");
const slog = std.log.scoped(.serdes);

/// Record definitions: field order maps positionally onto the arguments of
/// each line; `key` names the record (used by `apply` and `writeEntry`).
pub const ModuleCfgEntry = struct {
    pub const key = "module";

    name: []const u8,
    id: []const u8,
};

pub const ConnectCfgEntry = struct {
    pub const key = "connect";

    src: []const u8,
    src_id: []const u8,
    src_sock: []const u8,
    dst: []const u8,
    dst_id: []const u8,
    dst_sock: []const u8,
};

pub const ParamCfgEntry = struct {
    pub const key = "param";

    name: []const u8,
    id: []const u8,
    param: []const u8,
    value: []const u8,
    pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
};

pub const RemoveModuleCfgEntry = struct {
    pub const key = "removemodule";

    name: []const u8,
    id: []const u8,
};

/// Record kinds `apply` understands; tag names are the grammar keys.
/// `feedback` is an alias of `connect` and shares its record.
const Kind = enum {
    module,
    connect,
    feedback,
    param,
    removemodule,
};

comptime {
    if (!std.mem.eql(u8, @tagName(Kind.module), ModuleCfgEntry.key))
        @compileError("serdes: Kind.module must match ModuleCfgEntry.key");
    if (!std.mem.eql(u8, @tagName(Kind.connect), ConnectCfgEntry.key))
        @compileError("serdes: Kind.connect must match ConnectCfgEntry.key");
    if (!std.mem.eql(u8, @tagName(Kind.param), ParamCfgEntry.key))
        @compileError("serdes: Kind.param must match ParamCfgEntry.key");
    if (!std.mem.eql(u8, @tagName(Kind.removemodule), RemoveModuleCfgEntry.key))
        @compileError("serdes: Kind.removemodule must match RemoveModuleCfgEntry.key");
}

fn applyModule(pipe: *pipeline.Pipeline, cfg: ModuleCfgEntry, line_no: usize) !void {
    if (cfg.name.len == 0 or cfg.id.len == 0) {
        slog.warn("line {d}: incomplete module line, skipping", .{line_no});
        return;
    }
    const fullname = try std.mem.concat(pipe.allocator, u8, &.{ cfg.name, ":", cfg.id });
    defer pipe.allocator.free(fullname);
    if (pipe.module_name_map.contains(fullname)) return; // dedup
    if (pipe.repo.get(cfg.name) == null) {
        slog.warn("line {d}: unknown module '{s}', skipping", .{ line_no, cfg.name });
        return;
    }
    _ = try pipe.addModuleNoRecord(cfg.id, cfg.name);
}

fn applyRemoveModule(pipe: *pipeline.Pipeline, cfg: RemoveModuleCfgEntry, line_no: usize) !void {
    if (cfg.name.len == 0 or cfg.id.len == 0) {
        slog.warn("line {d}: incomplete removemodule line, skipping", .{line_no});
        return;
    }
    pipe.removeModuleByName(cfg.name, cfg.id) catch |err| {
        slog.warn("line {d}: removemodule failed ({}), skipping", .{ line_no, err });
    };
}

fn applyConnect(pipe: *pipeline.Pipeline, cfg: ConnectCfgEntry, line_no: usize) !void {
    if (cfg.dst.len == 0 or cfg.dst_id.len == 0 or cfg.dst_sock.len == 0) {
        slog.warn("line {d}: incomplete connect line, skipping", .{line_no});
        return;
    }
    // A `-1` source encodes an explicit disconnect
    if (std.mem.eql(u8, cfg.src, "-1")) {
        pipe.disconnectModuleByNameNoRecord(cfg.dst, cfg.dst_id, cfg.dst_sock) catch |err| {
            slog.warn("line {d}: disconnect failed ({}), skipping", .{ line_no, err });
        };
        return;
    }
    if (cfg.src.len == 0 or cfg.src_id.len == 0 or cfg.src_sock.len == 0) {
        slog.warn("line {d}: incomplete connect line, skipping", .{line_no});
        return;
    }
    pipe.connectModulesByNameNoRecord(cfg.src, cfg.src_id, cfg.src_sock, cfg.dst, cfg.dst_id, cfg.dst_sock) catch |err| {
        slog.warn("line {d}: connect failed ({}), skipping", .{ line_no, err });
    };
}

fn applyParam(pipe: *pipeline.Pipeline, cfg: ParamCfgEntry, line_no: usize) !void {
    if (cfg.name.len == 0 or cfg.id.len == 0 or cfg.param.len == 0) {
        slog.warn("line {d}: incomplete param line, skipping", .{line_no});
        return;
    }

    const fullname = try std.mem.concat(pipe.allocator, u8, &.{ cfg.name, ":", cfg.id });
    defer pipe.allocator.free(fullname);
    const mod_handle = pipe.module_name_map.get(fullname) orelse {
        slog.warn("line {d}: unknown module '{s}', skipping", .{ line_no, fullname });
        return;
    };
    const mod = try pipe.module_pool.getPtr(mod_handle);
    const idx = mod.getParamIndex(cfg.param) catch {
        slog.warn("line {d}: unknown parameter '{s}', skipping", .{ line_no, cfg.param });
        return;
    };
    const param = mod.params[idx] orelse {
        slog.warn("line {d}: unknown parameter '{s}', skipping", .{ line_no, cfg.param });
        return;
    };
    const pdesc = param.desc;
    switch (pdesc.typ) {
        .f32 => {
            var value_tokens = std.mem.splitScalar(u8, cfg.value, ':');
            for (0..pdesc.len) |i| {
                const tok = value_tokens.next() orelse "";
                const v: f32 = if (tok.len == 0) 0 else std.fmt.parseFloat(f32, tok) catch {
                    slog.warn("line {d}: unparseable f32 '{s}', skipping", .{ line_no, tok });
                    return;
                };
                @memcpy(param.bytes[i * 4 ..][0..4], std.mem.asBytes(&v));
            }
        },
        .i32 => {
            var value_tokens = std.mem.splitScalar(u8, cfg.value, ':');
            for (0..pdesc.len) |i| {
                const tok = value_tokens.next() orelse "";
                const v: i32 = if (tok.len == 0) 0 else std.fmt.parseInt(i32, tok, 10) catch {
                    slog.warn("line {d}: unparseable i32 '{s}', skipping", .{ line_no, tok });
                    return;
                };
                @memcpy(param.bytes[i * 4 ..][0..4], std.mem.asBytes(&v));
            }
        },
        .str => {
            if (cfg.value.len >= pdesc.len) {
                slog.warn("line {d}: string value too long for param '{s}', skipping", .{ line_no, pdesc.name });
                return;
            }
            @memset(param.bytes, 0); // clear stale tail so string reads stop at the NUL
            @memcpy(param.bytes[0..cfg.value.len], cfg.value);
        },
    }
}

/// This function serializes the current state of the pipeline into a colonconfig format.
/// It should only ever be used for history compression.
pub fn serialize(pipe: *pipeline.Pipeline, writer: *std.Io.Writer) !void {
    // modules
    var it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        try colonconfig.writeEntry(writer, ModuleCfgEntry, .{ mod.name, mod.id });
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
            try colonconfig.writeEntry(writer, ConnectCfgEntry, .{
                src_mod.name, src_mod.id, src_sock.name,
                mod.name,     mod.id,     sock.name,
            });
        }
    }

    // params: one line per declared param
    it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        for (mod.params) |maybe_param| {
            const param = maybe_param orelse continue;
            switch (param.value()) {
                inline else => |v| try colonconfig.writeEntry(writer, ParamCfgEntry, .{
                    mod.name, mod.id, param.desc.name, v,
                }),
            }
        }
    }
}

/// This function deserializes the colonconfig-formatted text into the pipeline state.
/// It should only ever be used for history replay as it does not record any new history.
pub fn deserialize(pipe: *pipeline.Pipeline, text: []const u8) !void {
    var line_no: usize = 0;
    var lit: colonconfig.LineIterator = .init(std.Io.Reader.fixed(text));
    while (lit.next() catch unreachable) |line_in| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, line_in, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        const split = colonconfig.splitKey(line);
        const kind = std.meta.stringToEnum(Kind, split.key) orelse {
            slog.warn("line {d}: unknown key '{s}', skipping", .{ line_no, split.key });
            continue;
        };
        switch (kind) {
            .module => try applyModule(pipe, colonconfig.parseArgs(ModuleCfgEntry, split.args), line_no),
            .connect, .feedback => try applyConnect(pipe, colonconfig.parseArgs(ConnectCfgEntry, split.args), line_no),
            .param => try applyParam(pipe, colonconfig.parseArgs(ParamCfgEntry, split.args), line_no),
            .removemodule => try applyRemoveModule(pipe, colonconfig.parseArgs(RemoveModuleCfgEntry, split.args), line_no),
        }
    }
}
