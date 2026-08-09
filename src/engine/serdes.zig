//! Plaintext (de)serialization of pipeline state in the vkdt `.pst` line
//! grammar: `module:`, `connect:`, `param:` records, `:`-delimited, no
//! whitespace trimming, `#` full-line comments.
//!
//! `serialize` writes modules, then connects (destination-side only), then
//! params. `deserialize` applies onto an existing pipeline and mirrors vkdt's
//! warn-and-continue loader: unknown modules/params/commands, failed connects,
//! and unparseable numbers log a warning with the line number and are skipped;
//! only allocator errors propagate.

const std = @import("std");
const api = @import("modules/api.zig");
const pipeline = @import("pipeline.zig");
const Modules = @import("modules/modules.zig");
const slog = std.log.scoped(.serdes);

pub fn serialize(pipe: *pipeline.Pipeline, writer: *std.Io.Writer) !void {
    // modules
    var it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        try writer.print("module:{s}:{s}\n", .{ mod.desc.name, mod.id });
    }

    // connects: one line per edge, from the destination side, input sockets only
    it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        for (mod.desc.sockets) |maybe_sock| {
            const sock = maybe_sock orelse continue;
            if (sock.type.direction() != .input) continue;
            const conn = sock.private.connected_to_module orelse continue;
            const src_mod = try pipe.module_pool.getPtr(conn.item);
            const src_sock = src_mod.desc.sockets[conn.socket_idx] orelse continue;
            try writer.print("connect:{s}:{s}:{s}:{s}:{s}:{s}\n", .{
                src_mod.desc.name, src_mod.id, src_sock.name,
                mod.desc.name,     mod.id,     sock.name,
            });
        }
    }

    // params: only initialized ones (never-initialized params have no live value)
    it = pipe.module_pool.liveHandles();
    while (it.next()) |handle| {
        const mod = try pipe.module_pool.getPtr(handle);
        for (mod.desc.params, 0..) |maybe_pdesc, idx| {
            const pdesc = maybe_pdesc orelse continue;
            const param = mod.params[idx] orelse continue;
            switch (pdesc.typ) {
                .f32, .i32 => {
                    try writer.print("param:{s}:{s}:{s}:", .{ mod.desc.name, mod.id, pdesc.name });
                    for (0..pdesc.len) |i| {
                        if (i != 0) try writer.writeByte(':');
                        const raw = param.bytes[i * 4 ..][0..4];
                        switch (pdesc.typ) {
                            .f32 => try writer.print("{d}", .{std.mem.bytesToValue(f32, raw)}),
                            .i32 => try writer.print("{d}", .{std.mem.bytesToValue(i32, raw)}),
                            else => unreachable,
                        }
                    }
                    try writer.writeByte('\n');
                },
                .str => {
                    try writer.print("param:{s}:{s}:{s}:{s}\n", .{ mod.desc.name, mod.id, pdesc.name, param.get([]const u8) });
                },
            }
        }
    }
}

pub fn deserialize(pipe: *pipeline.Pipeline, repository: *Modules.Repository, arena: std.mem.Allocator, text: []const u8) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    line_loop: while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var tokens = std.mem.splitScalar(u8, line, ':');
        const cmd = tokens.next() orelse continue;
        if (std.mem.eql(u8, cmd, "module")) {
            const name = tokens.next() orelse {
                slog.warn("preset line {d}: missing module name, skipping", .{line_no});
                continue;
            };
            const inst = tokens.next() orelse {
                slog.warn("preset line {d}: missing module instance, skipping", .{line_no});
                continue;
            };
            if (repository.get(name) == null) {
                slog.warn("preset line {d}: unknown module type '{s}', skipping", .{ line_no, name });
                continue;
            }
            const fullname = try std.mem.concat(pipe.allocator, u8, &.{ name, ":", inst });
            defer pipe.allocator.free(fullname);
            if (pipe.module_name_map.contains(fullname)) continue; // dedup
            const id_copy = try arena.dupe(u8, inst);
            _ = try pipe.addModuleDesc(id_copy, repository.get(name).?);
        } else if (std.mem.eql(u8, cmd, "connect")) {
            const src_name = tokens.next() orelse {
                slog.warn("preset line {d}: missing connect source type, skipping", .{line_no});
                continue;
            };
            const src_inst = tokens.next() orelse {
                slog.warn("preset line {d}: missing connect source instance, skipping", .{line_no});
                continue;
            };
            const src_sock = tokens.next() orelse {
                slog.warn("preset line {d}: missing connect source socket, skipping", .{line_no});
                continue;
            };
            const dst_name = tokens.next() orelse {
                slog.warn("preset line {d}: missing connect destination type, skipping", .{line_no});
                continue;
            };
            const dst_inst = tokens.next() orelse {
                slog.warn("preset line {d}: missing connect destination instance, skipping", .{line_no});
                continue;
            };
            const dst_sock = tokens.next() orelse {
                slog.warn("preset line {d}: missing connect destination socket, skipping", .{line_no});
                continue;
            };
            pipe.connectModulesByName(src_name, src_inst, src_sock, dst_name, dst_inst, dst_sock) catch |err| {
                slog.warn("preset line {d}: connect failed ({}), skipping", .{ line_no, err });
            };
        } else if (std.mem.eql(u8, cmd, "param")) {
            const name = tokens.next() orelse {
                slog.warn("preset line {d}: missing param module type, skipping", .{line_no});
                continue;
            };
            const inst = tokens.next() orelse {
                slog.warn("preset line {d}: missing param module instance, skipping", .{line_no});
                continue;
            };
            const parm = tokens.next() orelse {
                slog.warn("preset line {d}: missing param name, skipping", .{line_no});
                continue;
            };
            // The value is the entire remainder of the line verbatim, so it may
            // contain ':' (string params). Locate the terminating ':' of `parm`
            // by scanning colons from the start of the line.
            var search_from: usize = 0;
            var sep: ?usize = null;
            for (0..4) |_| {
                sep = std.mem.indexOfScalarPos(u8, line, search_from, ':') orelse break;
                search_from = sep.? + 1;
            }
            const value_rest = sep orelse {
                slog.warn("preset line {d}: malformed param line, skipping", .{line_no});
                continue;
            };
            const rest = line[value_rest + 1 ..];

            const fullname = try std.mem.concat(pipe.allocator, u8, &.{ name, ":", inst });
            defer pipe.allocator.free(fullname);
            const mod_handle = pipe.module_name_map.get(fullname) orelse {
                slog.warn("preset line {d}: unknown module '{s}', skipping", .{ line_no, fullname });
                continue;
            };
            const mod = try pipe.module_pool.getPtr(mod_handle);
            const idx = mod.getParamIndex(parm) catch {
                slog.warn("preset line {d}: unknown parameter '{s}', skipping", .{ line_no, parm });
                continue;
            };
            const pdesc = mod.desc.params[idx].?;
            const param = mod.params[idx] orelse {
                slog.warn("preset line {d}: parameter '{s}' is not initialized, skipping", .{ line_no, pdesc.name });
                continue;
            };
            switch (pdesc.typ) {
                .f32 => {
                    var value_tokens = std.mem.splitScalar(u8, rest, ':');
                    for (0..pdesc.len) |i| {
                        const tok = value_tokens.next() orelse "";
                        const v: f32 = if (tok.len == 0) 0 else std.fmt.parseFloat(f32, tok) catch {
                            slog.warn("preset line {d}: unparseable f32 '{s}', skipping", .{ line_no, tok });
                            continue :line_loop;
                        };
                        @memcpy(param.bytes[i * 4 ..][0..4], std.mem.asBytes(&v));
                    }
                },
                .i32 => {
                    var value_tokens = std.mem.splitScalar(u8, rest, ':');
                    for (0..pdesc.len) |i| {
                        const tok = value_tokens.next() orelse "";
                        const v: i32 = if (tok.len == 0) 0 else std.fmt.parseInt(i32, tok, 10) catch {
                            slog.warn("preset line {d}: unparseable i32 '{s}', skipping", .{ line_no, tok });
                            continue :line_loop;
                        };
                        @memcpy(param.bytes[i * 4 ..][0..4], std.mem.asBytes(&v));
                    }
                },
                .str => {
                    if (rest.len >= pdesc.len) {
                        slog.warn("preset line {d}: string value too long for param '{s}', skipping", .{ line_no, pdesc.name });
                        continue;
                    }
                    @memset(param.bytes, 0); // clear stale tail so Param.get stops at the NUL
                    @memcpy(param.bytes[0..rest.len], rest);
                },
            }
        } else {
            slog.warn("preset line {d}: unknown command '{s}', skipping", .{ line_no, cmd });
        }
    }
}
