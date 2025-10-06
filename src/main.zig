const std = @import("std");
const app = @import("ui/app.zig");
const tester = @import("pipe/modules/test.zig");

pub fn main() !void {
    // app.run();
    try tester.main();
}
