const std = @import("std");
const pie = @import("pie");
const zbench = @import("zbench");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;

const PipeBench = struct {
    pipeline: *Pipeline,

    const Self = @This();

    fn init(p: *Pipeline) Self {
        return .{ .pipeline = p };
    }

    pub fn run(self: Self, _: std.mem.Allocator) void {
        self.pipeline.rerouted = true;
        self.pipeline.dirty = true;
        try self.pipeline.run();
    }
};

fn runPipeBench(allocator: std.mem.Allocator, pipeline: *Pipeline) !void {
    const config: zbench.Config = .{
        // .iterations = 0,
        .max_iterations = 10,
        // .time_budget_ns = 1e9, // 1 second
    };
    var bench = zbench.Benchmark.init(allocator, config);
    defer bench.deinit();
    try bench.addParam("Pipeline Benchmark", &PipeBench.init(pipeline), .{});

    var buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();
}

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
    const mod_test_2nodes = try pipeline.addModule(pie.engine.modules.test_2nodes.module);
    const mod_test_o_2468 = try pipeline.addModule(pie.engine.modules.test_o_2468.module);

    pipeline.setModuleParam(mod_test_multiply, "multiplier", .{ .f32 = 2.0 }) catch unreachable;
    pipeline.setModuleParam(mod_test_multiply, "adder", .{ .i32 = 0 }) catch unreachable;

    pipeline.connectModulesName(mod_test_i_1234, "output", mod_test_multiply, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_multiply, "output", mod_test_2nodes, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_2nodes, "output", mod_test_o_2468, "input") catch unreachable;

    // try pipeline.run();
    // pipeline.rerouted = true;
    // pipeline.dirty = true;
    // try pipeline.run();

    try runPipeBench(allocator, &pipeline);
}
