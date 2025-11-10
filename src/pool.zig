const std = @import("std");

pub fn SingleColPool(comptime T: type) type {
    const Pool = @import("zpool").Pool;
    const INDEX_BITS = 16;
    const CYCLE_BITS = 16;
    const SingleColPoolType = Pool(INDEX_BITS, CYCLE_BITS, T, struct {
        val: T,
    });
    return struct {
        const Self = @This();
        pub const Handle = SingleColPoolType.Handle;

        pool: SingleColPoolType,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pool = SingleColPoolType.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
        }

        pub fn add(self: *Self, value: T) !SingleColPoolType.Handle {
            const handle = try self.pool.add(.{ .val = value });
            return handle;
        }

        pub fn get(self: Self, handle: SingleColPoolType.Handle) !T {
            const item = try self.pool.getColumn(handle, .val);
            return item;
        }

        pub fn isLiveHandle(self: *Self, handle: SingleColPoolType.Handle) bool {
            return self.pool.isLiveHandle(handle);
        }

        pub fn liveHandles(self: *Self) SingleColPoolType.LiveHandleIterator {
            return self.pool.liveHandles();
        }
    };
}

test "SingleColPool test" {
    const allocator = std.testing.allocator;
    var int_pool = SingleColPool(i32).init(allocator);
    defer int_pool.deinit();
    const IntHandle = SingleColPool(i32).Handle;

    const handle1 = try int_pool.add(42);
    const handle2 = try int_pool.add(100);

    const val1 = int_pool.get(handle1) catch unreachable;
    const val2 = int_pool.get(handle2) catch unreachable;

    try std.testing.expectEqual(val1, 42);
    try std.testing.expectEqual(val2, 100);

    try std.testing.expect(@TypeOf(handle1) == IntHandle);
    try std.testing.expect(@TypeOf(handle1) == @TypeOf(handle2));

    var count: u32 = 0;
    var live_iter = int_pool.liveHandles();
    while (live_iter.next()) |h| {
        _ = int_pool.get(h) catch unreachable;
        count += 1;
    }
    try std.testing.expectEqual(count, 2);
}
