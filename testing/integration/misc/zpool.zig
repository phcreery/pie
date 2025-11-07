const std = @import("std");

test "pool" {
    if (true) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;

    const Image = struct {
        data: []u8,
    };

    var module_pool = std.heap.MemoryPoolExtra(Image, .{}).init(allocator);
    defer module_pool.deinit();
    const user1 = try module_pool.create();
    defer module_pool.destroy(user1);

    const data = allocator.alloc(u8, 10) catch unreachable;
    defer allocator.free(data);
    user1.* = Image{
        .data = data,
    };
    std.log.info("Image data length: {}", .{user1.data.len});
}

test "zpool" {
    if (true) {
        return error.SkipZigTest;
    }
    const Pool = @import("zpool").Pool;
    const allocator = std.testing.allocator;

    const Image = struct {
        data: []u8,
    };
    const ImageInfoType = struct {
        width: u32,
        height: u32,
        format: u32,
    };

    // const ImagePtr = Image;
    // const ImageInfo = ImageInfoType;

    const ImagePool = Pool(16, 16, Image, struct {
        ptr: Image,
        info: ImageInfoType,
    });
    const ImageHandle = ImagePool.Handle;

    var imagePool = ImagePool.initCapacity(allocator, 100) catch unreachable;
    defer imagePool.deinit();

    const data = allocator.alloc(u8, 1 * 1 * 4) catch unreachable;
    defer allocator.free(data);
    // const ptr: *Image = allocator.alloc(Image) catch unreachable;
    // ptr.* = .{
    //     .data = data,
    // };
    const ptr: Image = .{
        .data = data,
    };
    const info: ImageInfoType = .{
        .width = 1,
        .height = 1,
        .format = 4,
    };
    const handle: ImageHandle = try imagePool.add(.{
        .ptr = ptr,
        .info = info,
    });

    // Use the handle...
    const image: Image = try imagePool.getColumn(handle, .ptr);
    std.log.info("Image: {}", .{image});

    var live_handles = imagePool.liveHandles();
    while (live_handles.next()) |h| {
        const i: Image = try imagePool.getColumn(h, .ptr);
        std.log.info("Image: {}", .{i});
    }
}
