const std = @import("std");

/// The global general-purpose allocator used throughout the code
// C allocator
// pub const gpa = std.heap.c_allocator;

// Zig GeneralPurposeAllocator allocator
// var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
// pub const gpa = general_purpose_allocator.allocator();

// pub const gpa = std.testing.allocator;

pub const gpa = std.heap.page_allocator;
