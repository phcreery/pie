const std = @import("std");
const builtin = @import("builtin");

// C allocator, fast and works with wasm
// pub const allocator = std.heap.c_allocator;

// Zig GeneralPurposeAllocator/DebugAllocator allocator
var gpa = std.heap.DebugAllocator(.{
    .stack_trace_frames = 6,
    .safety = true,
    .verbose_log = true,
}){};
pub const allocator = gpa.allocator();

// var general_purpose_allocator = std.heap.GeneralPurposeAllocator.init(builtin.page_size);

// pub const allocator = std.testing.allocator;

// pub const allocator = std.heap.page_allocator;

// pub const allocator = std.heap.wasm_allocator;

// var buffer: [1024]u8 = undefined;
// var fba = std.heap.FixedBufferAllocator.init(&buffer);
// const allocator = fba.allocator();
