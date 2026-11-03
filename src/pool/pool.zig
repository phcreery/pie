const std = @import("std");

/// Generational handle pool with dense storage for live items.
///
/// This keeps the old `Pool` API shape for compatibility with existing
/// pipeline code while replacing the internals with a floooh-style slot pool.
pub fn Pool(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        items: std.ArrayList(T) = .empty,
        dense_to_slot: std.ArrayList(u32) = .empty,
        free_slots: std.ArrayList(u32) = .empty,

        const Self = @This();
        const invalid_dense_index = std.math.maxInt(u32);

        const Slot = struct {
            generation: u32 = 1,
            dense_index: u32 = invalid_dense_index,
            live: bool = false,
        };

        pub const Handle = struct {
            id: u64,

            pub fn index(self: Handle) u32 {
                return @as(u32, @truncate(self.id));
            }

            pub fn generation(self: Handle) u32 {
                return @as(u32, @truncate(self.id >> 32));
            }
        };

        pub const Iterator = struct {
            pool: *const Self,
            next_slot: u32 = 0,

            pub fn next(self: *Iterator) ?Handle {
                while (self.next_slot < self.pool.slots.items.len) {
                    const slot_index = self.next_slot;
                    self.next_slot += 1;

                    const slot = self.pool.slots.items[slot_index];
                    if (!slot.live) continue;
                    return packHandle(slot_index, slot.generation);
                }
                return null;
            }
        };

        const ResolvedHandle = struct {
            slot_index: u32,
            dense_index: u32,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.items.items) |*item| {
                deinitValue(item);
            }
            self.slots.deinit(self.allocator);
            self.items.deinit(self.allocator);
            self.dense_to_slot.deinit(self.allocator);
            self.free_slots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn add(self: *Self, value: T) !Handle {
            const dense_index: u32 = @intCast(self.items.items.len);

            var slot_index: u32 = undefined;
            var generation: u32 = undefined;

            if (self.free_slots.pop()) |free_slot_index| {
                slot_index = free_slot_index;
                generation = self.slots.items[slot_index].generation;

                self.slots.items[slot_index] = .{
                    .generation = generation,
                    .dense_index = dense_index,
                    .live = true,
                };
            } else {
                slot_index = @intCast(self.slots.items.len);
                generation = 1;
                try self.slots.append(self.allocator, .{
                    .generation = generation,
                    .dense_index = dense_index,
                    .live = true,
                });
            }

            try self.items.append(self.allocator, value);
            errdefer _ = self.items.pop();

            try self.dense_to_slot.append(self.allocator, slot_index);
            errdefer _ = self.dense_to_slot.pop();

            return packHandle(slot_index, generation);
        }

        pub fn remove(self: *Self, handle: Handle) void {
            const resolved = self.resolveHandle(handle) orelse return;
            self.removeResolved(resolved);
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            const resolved = self.resolveHandle(handle) orelse return null;
            return &self.items.items[resolved.dense_index];
        }

        /// alias for `get()`, for compatibility with zpool
        pub fn getPtr(self: *Self, handle: Handle) !*T {
            return self.get(handle) orelse error.InvalidHandle;
        }

        pub fn len(self: *Self) usize {
            return self.items.items.len;
        }

        pub fn isLiveHandle(self: *Self, handle: Handle) bool {
            return self.resolveHandle(handle) != null;
        }

        /// alias for `iterator()`, for compatibility with zpool
        pub fn liveHandles(self: *Self) Iterator {
            return self.iterator();
        }

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        fn removeResolved(self: *Self, resolved: ResolvedHandle) void {
            const slot_index = resolved.slot_index;
            const dense_index = resolved.dense_index;
            const last_dense_index: u32 = @intCast(self.items.items.len - 1);

            deinitValue(&self.items.items[dense_index]);

            const moved_slot_index = self.dense_to_slot.items[last_dense_index];
            _ = self.items.swapRemove(dense_index);
            _ = self.dense_to_slot.swapRemove(dense_index);

            if (dense_index != last_dense_index) {
                self.slots.items[moved_slot_index].dense_index = dense_index;
            }

            self.slots.items[slot_index].dense_index = invalid_dense_index;
            self.slots.items[slot_index].live = false;
            self.slots.items[slot_index].generation = nextGeneration(self.slots.items[slot_index].generation);
            self.free_slots.append(self.allocator, slot_index) catch unreachable;
        }

        fn resolveHandle(self: *Self, handle: Handle) ?ResolvedHandle {
            const slot_index = unpackIndex(handle);
            if (slot_index >= self.slots.items.len) return null;

            const slot = self.slots.items[slot_index];
            if (!slot.live) return null;
            if (slot.generation != unpackGeneration(handle)) return null;
            if (slot.dense_index >= self.items.items.len) return null;

            return .{
                .slot_index = slot_index,
                .dense_index = slot.dense_index,
            };
        }

        fn deinitValue(value: *T) void {
            switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => {
                    if (@hasDecl(T, "deinit")) {
                        value.deinit();
                    }
                },
                else => {},
            }
        }

        fn nextGeneration(generation: u32) u32 {
            const next = generation +% 1;
            return if (next == 0) 1 else next;
        }

        fn packHandle(slot_index: u32, generation: u32) Handle {
            return .{
                .id = (@as(u64, generation) << 32) | @as(u64, slot_index),
            };
        }

        fn unpackIndex(handle: Handle) u32 {
            return handle.index();
        }

        fn unpackGeneration(handle: Handle) u32 {
            return handle.generation();
        }
    };
}

test "Pool simple add/get/remove/iterate" {
    const Element = struct {
        value: i32,
    };

    const allocator = std.testing.allocator;
    var pool: Pool(Element) = .init(allocator);
    defer pool.deinit();
    const IntHandle = Pool(Element).Handle;

    const handle1 = try pool.add(.{ .value = 42 });
    const handle2 = try pool.add(.{ .value = 100 });
    const handle3 = try pool.add(.{ .value = 200 });

    const val1 = pool.get(handle1) orelse unreachable;
    const val2 = pool.get(handle2) orelse unreachable;
    const val3 = pool.get(handle3) orelse unreachable;

    try std.testing.expectEqual(@as(i32, 42), val1.value);
    try std.testing.expectEqual(@as(i32, 100), val2.value);
    try std.testing.expectEqual(@as(i32, 200), val3.value);

    try std.testing.expect(@TypeOf(handle1) == IntHandle);
    try std.testing.expect(@TypeOf(handle1) == @TypeOf(handle2));
    try std.testing.expectEqual(@as(usize, 3), pool.len());

    var list = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer list.deinit(allocator);
    var iter = pool.iterator();
    while (iter.next()) |handle| {
        const el = pool.get(handle) orelse unreachable;
        try list.append(allocator, el.value);
    }
    try std.testing.expect(std.mem.indexOfScalar(i32, list.items, 42) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, list.items, 100) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, list.items, 200) != null);

    pool.remove(handle2);
    try std.testing.expectEqual(@as(usize, 2), pool.len());
    try std.testing.expect(!pool.isLiveHandle(handle2));
    try std.testing.expect(pool.get(handle2) == null);

    var list2 = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer list2.deinit(allocator);
    var iter2 = pool.iterator();
    while (iter2.next()) |handle| {
        const el = pool.get(handle) orelse unreachable;
        try list2.append(allocator, el.value);
    }
    try std.testing.expect(std.mem.indexOfScalar(i32, list2.items, 42) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, list2.items, 200) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, list2.items, 100) == null);
}

test "Pool reuses slot with new generation" {
    const allocator = std.testing.allocator;
    var pool: Pool(i32) = .init(allocator);
    defer pool.deinit();

    const handle1 = try pool.add(11);
    pool.remove(handle1);
    const handle2 = try pool.add(22);

    try std.testing.expect(handle1.index() == handle2.index());
    try std.testing.expect(handle1.generation() != handle2.generation());
    try std.testing.expect(!pool.isLiveHandle(handle1));
    try std.testing.expect(pool.isLiveHandle(handle2));
    try std.testing.expectEqual(@as(i32, 22), (try pool.getPtr(handle2)).*);
}

test "Pool remove calls T.deinit" {
    const Element = struct {
        value: i32,
        counter: *u32,

        pub fn deinit(self: *@This()) void {
            _ = self.value;
            self.counter.* += 1;
        }
    };

    const allocator = std.testing.allocator;
    var pool: Pool(Element) = .init(allocator);
    defer pool.deinit();

    var counter: u32 = 0;
    const handle = try pool.add(.{ .value = 7, .counter = &counter });
    pool.remove(handle);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "Pool supports remove during iteration" {
    const allocator = std.testing.allocator;
    var pool: Pool(i32) = .init(allocator);
    defer pool.deinit();

    const h1 = try pool.add(1);
    const h2 = try pool.add(2);
    const h3 = try pool.add(3);

    var seen: usize = 0;
    var it = pool.liveHandles();
    while (it.next()) |handle| {
        seen += 1;
        if (handle.id == h2.id) {
            pool.remove(handle);
        }
    }

    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expect(pool.isLiveHandle(h1));
    try std.testing.expect(!pool.isLiveHandle(h2));
    try std.testing.expect(pool.isLiveHandle(h3));
    try std.testing.expectEqual(@as(usize, 2), pool.len());
}
