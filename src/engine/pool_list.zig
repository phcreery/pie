const std = @import("std");

/// A memory pool that also maintains a doubly linked list of its elements.
/// This uses zig's new intrusive linked list feature so you have to provide
/// a field name in T that is of type `std.DoublyLinkedList.Node`.
pub fn PoolList(comptime T: type, comptime ll_node_field: []const u8) type {
    if (!@hasField(T, ll_node_field)) {
        @compileError("T must not have a field named " ++ ll_node_field);
    }
    return struct {
        pool: std.heap.MemoryPoolExtra(T, .{}),
        ll: std.DoublyLinkedList,

        const Handle = struct {
            id: usize,
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pool = std.heap.MemoryPoolExtra(T, .{}).init(allocator),
                .ll = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
        }

        pub fn add(self: *Self, value: T) !*T {
            const val = try self.pool.create();
            val.* = value;
            const node: *std.DoublyLinkedList.Node = &@field(val, ll_node_field);
            self.ll.append(node);
            return val;
        }

        pub fn remove(self: *Self, item: *T) void {
            var node = @field(item, ll_node_field);
            self.ll.remove(&node);
            self.pool.destroy(item);
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .it = self.ll.first,
            };
        }

        const Iterator = struct {
            it: ?*std.DoublyLinkedList.Node,

            pub fn next(self: *Iterator) ?*T {
                const node = self.it orelse return null;
                self.it = self.it.?.next;
                return @fieldParentPtr(ll_node_field, node);
            }
        };
    };
}

test "PoolList simple test" {
    const Element = struct {
        value: i32,
        node: std.DoublyLinkedList.Node = .{},
    };

    const allocator = std.testing.allocator;
    var int_pool = PoolList(Element, "node").init(allocator);
    defer int_pool.deinit();

    // ADD
    const handle1 = try int_pool.add(Element{ .value = 42 });
    const handle2 = try int_pool.add(Element{ .value = 100 });
    const handle3 = try int_pool.add(Element{ .value = 200 });

    try std.testing.expectEqual(handle1.value, 42);
    try std.testing.expectEqual(handle2.value, 100);
    try std.testing.expectEqual(handle3.value, 200);

    try std.testing.expect(@TypeOf(handle1) == *Element);
    try std.testing.expect(@TypeOf(handle1) == @TypeOf(handle2));

    // LEN
    try std.testing.expect(int_pool.ll.len() == 3);

    // ITERATE
    var list = std.ArrayList(i32).initCapacity(allocator, 0) catch unreachable;
    defer list.deinit(allocator);
    var iter = int_pool.iterator();
    while (iter.next()) |h| {
        list.append(allocator, h.value) catch unreachable;
    }
    try std.testing.expectEqualSlices(i32, &[_]i32{ 42, 100, 200 }, list.items);

    // REMOVE
    int_pool.remove(handle2);
    try std.testing.expect(int_pool.ll.len() == 2);
    std.debug.print("handle2: {any}\n", .{handle2});

    // ITERATE AGAIN
    var list2 = std.ArrayList(i32).initCapacity(allocator, 0) catch unreachable;
    defer list2.deinit(allocator);
    var iter2 = int_pool.iterator();
    while (iter2.next()) |h| {
        list2.append(allocator, h.value) catch unreachable;
    }
    try std.testing.expectEqualSlices(i32, &[_]i32{ 42, 200 }, list2.items);
}
