const std = @import("std");
const app = @import("ui/app.zig");
// const opencl_tester = @import("engine/pipe/scratch/opencl_test.zig");
const webgpu_tester = @import("engine/pipe/scratch/webgpu_test.zig");
const webgpu_compute_tester = @import("engine/pipe/scratch/webgpu_compute_test.zig");
// const libraw_tester = @import("engine/scratch/libraw_test.zig");

pub const gpu = @import("engine/gpu.zig");
pub const iraw = @import("engine/pipe/modules/i-raw/i-raw.zig");

pub fn main() !void {
    // app.run();
    // try opencl_tester.main();
    // try libraw_tester.main();
    // try webgpu_tester.main();
    try webgpu_compute_tester.main();
}

test {
    _ = @import("engine/pipe/modules/shared/bayer_filters.zig");
    _ = @import("engine/pipe/modules/i-raw/i-raw.zig");
}
