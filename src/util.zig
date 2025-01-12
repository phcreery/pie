const std = @import("std");

/// The global general-purpose allocator used throughout the code
// C allocator
// pub const gpa = std.heap.c_allocator;

// Zig allocator
var zig_gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const gpa = zig_gpa.allocator();
