const std = @import("std");
const pie = @import("pie");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;

test "simple module test" {
    const allocator = std.testing.allocator;

    const cp_out = pie.cli.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init();
    defer gpu_instance.deinit();

    var pipeline = Pipeline.init(allocator, &gpu_instance) catch unreachable;
    defer pipeline.deinit();

    _ = try pipeline.addModule(pie.engine.modules.test_i_1234.module);
    // _ = try pipeline.addModule(pie.engine.modules.test_double.module);
    _ = try pipeline.addModule(pie.engine.modules.test_multiply.module);
    _ = try pipeline.addModule(pie.engine.modules.test_o_2468.module);

    try pipeline.run();
}
