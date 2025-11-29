const std = @import("std");

/// A memory pool that also maintains a hash map of its elements.
/// This allows for fast lookups and removals by handle.
pub fn HashMapPool(comptime T: type) type {
    return struct {
        pool: std.heap.MemoryPoolExtra(T, .{}),
        hash_map: std.AutoHashMap(usize, *T),
        current_id: usize = 0,

        pub const column_fields = std.meta.fields(T);
        const Key = usize;
        pub const Handle = struct {
            id: Key,
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pool = std.heap.MemoryPoolExtra(T, .{}).init(allocator),
                .hash_map = std.AutoHashMap(Key, *T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            switch (@typeInfo(T)) {
                .optional => |optional_info| {
                    if (@hasDecl(optional_info.child, "deinit")) {
                        var it = self.iterator();
                        while (it.next()) |handle| {
                            // std.debug.print("Deinit optional handle {d}\n", .{handle.id});
                            const value = self.get(handle) orelse continue;
                            value.*.?.deinit();
                        }
                    }
                },
                .@"struct" => {
                    if (@hasDecl(T, "deinit")) {
                        var it = self.iterator();
                        while (it.next()) |handle| {
                            // std.debug.print("Deinit struct handle {d}\n", .{handle.id});
                            const value = self.get(handle) orelse continue;
                            value.deinit();
                        }
                    }
                },
                else => {},
            }

            self.pool.deinit();
            self.hash_map.deinit();
        }

        pub fn add(self: *Self, value: T) !Handle {
            const item = try self.pool.create();
            item.* = value;
            try self.hash_map.put(self.current_id, item);
            self.current_id += 1;
            return Handle{ .id = self.current_id - 1 };
        }

        pub fn remove(self: *Self, handle: Handle) void {
            const item = self.hash_map.get(handle.id);
            if (item) |ptr| {
                self.pool.destroy(@alignCast(ptr));
            }
            _ = self.hash_map.remove(handle.id);
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            return self.hash_map.get(handle.id);
        }

        /// alias for `get()` for compatibility with zpool
        pub fn getPtr(self: *Self, handle: Handle) !*T {
            const val = self.hash_map.get(handle.id);
            if (val) |ptr| {
                return ptr;
            } else {
                return error.InvalidHandle;
            }
        }

        pub fn len(self: *Self) usize {
            var count: usize = 0;
            var it = self.hash_map.iterator();
            while (it.next()) |_| {
                count += 1;
            }
            return count;
        }

        /// alias for `iterator()` for compatibility with zpool
        pub fn liveHandles(self: *Self) Iterator {
            return self.iterator();
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .it = self.hash_map.iterator(),
            };
        }
        pub const Iterator = struct {
            it: std.AutoHashMap(Key, *T).Iterator,

            pub fn next(self: *Iterator) ?Handle {
                const entry = self.it.next() orelse return null;
                return Handle{ .id = entry.key_ptr.* };
            }
        };
    };
}

test "PoolList simple test" {
    const Element = struct {
        value: i32,
    };

    const allocator = std.testing.allocator;
    var pool = HashMapPool(Element).init(allocator);
    defer pool.deinit();
    const IntHandle = HashMapPool(Element).Handle;

    // ADD
    const handle1 = try pool.add(Element{ .value = 42 });
    const handle2 = try pool.add(Element{ .value = 100 });
    const handle3 = try pool.add(Element{ .value = 200 });

    const val1 = pool.get(handle1) orelse unreachable;
    const val2 = pool.get(handle2) orelse unreachable;
    const val3 = pool.get(handle3) orelse unreachable;

    try std.testing.expectEqual(val1.value, 42);
    try std.testing.expectEqual(val2.value, 100);
    try std.testing.expectEqual(val3.value, 200);

    try std.testing.expect(@TypeOf(handle1) == IntHandle);
    try std.testing.expect(@TypeOf(handle1) == @TypeOf(handle2));

    // LEN
    try std.testing.expect(pool.len() == 3);

    // ITERATE
    var list = std.ArrayList(i32).initCapacity(allocator, 0) catch unreachable;
    defer list.deinit(allocator);
    var iter = pool.iterator();
    while (iter.next()) |handle| {
        const el = pool.get(handle) orelse unreachable;
        list.append(allocator, el.value) catch unreachable;
    }
    _ = std.mem.indexOfScalar(i32, list.items, 42) orelse unreachable;
    _ = std.mem.indexOfScalar(i32, list.items, 100) orelse unreachable;
    _ = std.mem.indexOfScalar(i32, list.items, 200) orelse unreachable;

    // REMOVE
    pool.remove(handle2);
    try std.testing.expect(pool.len() == 2);

    // ITERATE AGAIN
    var list2 = std.ArrayList(i32).initCapacity(allocator, 0) catch unreachable;
    defer list2.deinit(allocator);
    var iter2 = pool.iterator();
    while (iter2.next()) |handle| {
        const el = pool.get(handle) orelse unreachable;
        list2.append(allocator, el.value) catch unreachable;
    }
    _ = std.mem.indexOfScalar(i32, list2.items, 42) orelse unreachable;
    _ = std.mem.indexOfScalar(i32, list2.items, 200) orelse unreachable;
}
