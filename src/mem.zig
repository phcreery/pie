const std = @import("std");
const builtin = @import("builtin");
const ztracy = @import("ztracy");

// C allocator, fast and works with wasm
// pub const allocator = std.heap.c_allocator;

// Zig GeneralPurposeAllocator/DebugAllocator allocator
var gpa = std.heap.DebugAllocator(.{
    .stack_trace_frames = 6,
    .safety = true,
    .verbose_log = true,
}){};
// Every host allocation made through this allocator shows up in Tracy's
// Memory view (live bytes, alloc/free timeline, leak candidates). With Tracy
// disabled the wrapper is bypassed entirely.
//
// This mirrors `ztracy.TracyAllocator`, minus its "resize/remap failed"
// messages: `DebugAllocator` cannot remap, so the normal alloc+copy+free
// fallback would flood the message timeline.
const TrackingAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ra);
        if (result) |ptr| ztracy.Alloc(ptr, len);
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawResize(buf, alignment, new_len, ra);
        if (result) {
            ztracy.Free(buf.ptr);
            ztracy.Alloc(buf.ptr, new_len);
        }
        return result;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(buf, alignment, new_len, ra);
        if (result) |ptr| {
            ztracy.Free(buf.ptr);
            ztracy.Alloc(ptr, new_len);
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
        ztracy.Free(buf.ptr);
    }
};

var tracking_allocator = TrackingAllocator{ .child = gpa.allocator() };
pub const allocator = if (ztracy.enabled) tracking_allocator.allocator() else gpa.allocator();

// var general_purpose_allocator = std.heap.GeneralPurposeAllocator.init(builtin.page_size);

// pub const allocator = std.testing.allocator;

// pub const allocator = std.heap.page_allocator;

// pub const allocator = std.heap.wasm_allocator;
