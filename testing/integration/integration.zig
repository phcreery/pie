const std = @import("std");
// const pie = @import("pie");
// const libraw = @import("libraw");
// const zigimg = @import("zigimg");

// std.ArrayList(comptime T: type)

pub fn main() !void {
    // std.log.info("Starting Integration tests", .{});
}

test {
    // _ = @import("engine/gpu.zig");
    _ = @import("engine/pipeline.zig");

    // _ = @import("fullsize/DSC_6765.zig");

    // _ = @import("misc/zpool.zig");
    // _ = @import("misc/musubi.zig");
    // _ = @import("misc/zig-graph.zig");
}

const TF = struct {
    n: i32,
    T: type,

    pub fn printType(self: TF) void {
        std.log.info("Type T: {any}", .{self.T});
    }
};

test "1" {
    const a = TF{ .n = 4, .T = f16 };
    // _ = a;
    a.printType();
}
