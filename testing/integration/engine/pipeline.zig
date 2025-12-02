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

    const mod_test_i_1234 = try pipeline.addModule(pie.engine.modules.test_i_1234.module);
    const mod_test_multiply = try pipeline.addModule(pie.engine.modules.test_multiply.module);
    const mod_test_o_2468 = try pipeline.addModule(pie.engine.modules.test_o_2468.module);

    const multiplier = pipeline.getModuleParamPtr(mod_test_multiply, "multiplier") orelse unreachable;
    multiplier.*.value.f32 = 2.0;
    const adder = pipeline.getModuleParamPtr(mod_test_multiply, "adder") orelse unreachable;
    adder.*.value.i32 = 0;

    pipeline.connectModules(mod_test_i_1234, "output", mod_test_multiply, "input") catch unreachable;
    pipeline.connectModules(mod_test_multiply, "output", mod_test_o_2468, "input") catch unreachable;

    try pipeline.run();
}
