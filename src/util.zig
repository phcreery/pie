const std = @import("std");
const builtin = @import("builtin");

// C allocator, works with wasm
pub const gpa = std.heap.c_allocator;

// Zig GeneralPurposeAllocator allocator
// var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
//     .stack_trace_frames = 6,
//     .safety = true,
//     .verbose_log = true,
// }){};
// pub const gpa = general_purpose_allocator.allocator();

// pub const gpa = std.testing.allocator;

// pub const gpa = std.heap.page_allocator;

// pub const gpa = std.heap.wasm_allocator;
