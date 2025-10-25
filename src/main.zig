const std = @import("std");
const app = @import("ui/app.zig");

pub const engine = @import("engine/engine.zig");
pub const iraw = @import("engine/modules/i-raw/i-raw.zig");

// const webgpu_tester = @import("engine/scratch/webgpu_test.zig");
// const webgpu_compute_tester = @import("engine/scratch/webgpu_compute_test.zig");

pub fn main() !void {
    app.run();
    // try webgpu_tester.main();
    // try webgpu_compute_tester.main();
}

test {
    _ = @import("engine/gpu.zig");
    _ = @import("engine/modules/shared/CFA.zig");
    _ = @import("engine/modules/i-raw/i-raw.zig");
}
