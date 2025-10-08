const std = @import("std");
const app = @import("ui/app.zig");
// const tester = @import("engine/pipe/modules/opencl_test.zig");
// const tester = @import("engine/libraw_test.zig");

pub fn main() !void {
    app.run();
    // try tester.main();
}
