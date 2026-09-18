//! Append-only log of pipeline-edit deltas, stored as text lines
//!
//! Undo/redo are a cursor into the list: committed items are `items[0..cursor]`
//! and `items[cursor..]` is the redo tail. Any new append drops the redo tail
//! first (standard undo-buffer semantics). Rolling back to an item is done by
//! replaying every recorded delta 0..cursor onto a cleared pipeline — the same
//! replay-from-empty model vkdt uses — so the history is the *source of truth*
//! and can be reserialized/round-tripped like a config file.

const std = @import("std");

fn BaseType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) {
        return info.pointer.child;
    }
    return T;
}

pub const HistoryConfig = struct {
    /// Merge an edit that repeats the same recompute key within this many
    /// seconds into the previous matching step instead of appending a new one.
    /// 0 disables coalescing (every call appends).
    window_secs: f32 = 0.0,
    /// How far back to scan for a matching key (bounded, like vkdt's lookback).
    max_steps: usize = 2,
};

pub fn HistList(comptime TKey: type, comptime TValue: type) type {
    return struct {
        allocator: std.mem.Allocator,
        /// Owns `items` storage and every `Item.line`/`Item.key` slice. Freed all
        /// at once on `deinit`; nothing here is freed individually.
        arena: std.heap.ArenaAllocator,
        /// Source of monotonic time (this zig snapshot surfaces time through
        /// `std.Io`); used to coalesce edits within a window.
        io: std.Io,
        items: std.ArrayList(Item),
        /// Committed marker. `items[0..cursor]` is undoable state; `items[cursor..]`
        /// is the redo tail.
        cursor: usize = 0,

        pub const Item = struct {
            /// Owned by `History.arena`, so it stays stable across appends.
            line: TValue,
            /// Coalescing key (e.g. `"param:i-raw:01:wb_mode"`), distinct from the
            /// full line so two edits of one param merge regardless of the value.
            key: ?TKey = null,
            /// Monotonic time of the append (nanoseconds), for coalescing.
            time: i64 = 0,
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            const arena = std.heap.ArenaAllocator.init(allocator);
            return .{
                .allocator = allocator,
                .arena = arena,
                .io = io,
                .items = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }

        // ----- introspection -----

        /// Committed, undoable edits (index < cursor).
        pub fn committed(self: *const Self) []const Item {
            return self.items.items[0..self.cursor];
        }

        /// Every recorded step, including the redo tail (index < count).
        pub fn all(self: *const Self) []const Item {
            return self.items.items;
        }

        /// Total recorded steps including the redo tail.
        pub fn count(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn canUndo(self: *const Self) bool {
            return self.cursor > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.cursor < self.items.items.len;
        }

        // ----- editing the list -----

        /// Undo one step: shrink the committed cursor (keeps the redo tail).
        pub fn undo(self: *Self) void {
            if (self.cursor > 0) self.cursor -= 1;
        }

        /// Redo one step: grow the commit cursor toward the tip.
        pub fn redo(self: *Self) void {
            if (self.cursor < self.items.items.len) self.cursor += 1;
        }

        /// Jump to an arbitrary commit point (0 = before everything).
        /// The caller is responsible for actually rebuilding pipeline state.
        pub fn setCursor(self: *Self, n: usize) void {
            self.cursor = @min(n, self.items.items.len);
        }

        /// Append a delta line without coalescing.
        pub fn append(self: *Self, line: TValue) !void {
            self.dropRedoTail();
            const owned = try self.arena.allocator().dupe(BaseType(TValue), line);
            try self.items.append(self.arena.allocator(), .{
                .line = owned,
                .time = self.nowNs(),
            });
            self.cursor = self.items.items.len;
        }

        /// Append a delta line, coalescing into the most recent step with the same
        /// `key` when it happened within `window_secs` (in-place replacement).
        pub fn appendKeyed(
            self: *Self,
            line: TValue,
            key: TKey,
            cfg: HistoryConfig,
        ) !void {
            self.dropRedoTail();

            const owned = try self.arena.allocator().dupe(BaseType(TValue), line);
            const now = self.nowNs();

            if (cfg.window_secs > 0 and self.items.items.len > 0) {
                const window_ns: i64 = @intFromFloat(cfg.window_secs * 1e9);
                const n = self.items.items.len; // == cursor after dropRedoTail
                const start = n - @min(cfg.max_steps, n);
                var i = n;
                while (i > start) : (i -= 1) {
                    const it = &self.items.items[i - 1];
                    const it_key = it.key orelse continue;
                    if (!std.mem.eql(u8, it_key, key)) continue;
                    if (now - it.time >= window_ns) break; // too old to coalesce into
                    // coalesce: replace this step in place, keep redo semantics
                    it.line = owned;
                    it.time = now;
                    self.cursor = self.items.items.len;
                    return;
                }
            }

            // no coalesce: append a fresh step (record the key so a later drag can merge)
            const owned_key = if (cfg.window_secs > 0)
                try self.arena.allocator().dupe(BaseType(TKey), key)
            else
                null;
            try self.items.append(self.arena.allocator(), .{
                .line = owned,
                .key = owned_key,
                .time = now,
            });
            self.cursor = self.items.items.len;
        }

        /// Permanently discard the redo tail (called before any append that would
        /// otherwise be overwritten by a new step).
        fn nowNs(self: *const HistList(TKey, TValue)) i64 {
            return @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds);
        }

        /// Called inline: emulate the "shrink redo tail" invariant so that an append
        /// after an undo invalidates the discarded states.
        fn dropRedoTail(self: *HistList(TKey, TValue)) void {
            // Shrink the ArrayList back to where the cursor sits, permanently
            // discarding the redo tail. Uses shrinkRetainingCapacity so the backing
            // arena memory (which holds the strings) survives; we only forget items.
            self.items.items.len = self.cursor;
        }
    };
}
