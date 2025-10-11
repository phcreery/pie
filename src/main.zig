const std = @import("std");
const app = @import("ui/app.zig");
// const opencl_tester = @import("engine/pipe/scratch/opencl_test.zig");
const webgpu_tester = @import("engine/pipe/scratch/webgpu_test.zig");
const webgpu_compute_tester = @import("engine/pipe/scratch/webgpu_compute_test.zig");
// const libraw_tester = @import("engine/scratch/libraw_test.zig");

pub const engine = @import("engine/engine.zig");

pub fn main() !void {
    // app.run();
    // try opencl_tester.main();
    // try libraw_tester.main();
    // try webgpu_tester.main();
    try webgpu_compute_tester.main();
}
