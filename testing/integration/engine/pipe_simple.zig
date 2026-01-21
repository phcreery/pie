const std = @import("std");
const pie = @import("pie");
const zbench = @import("zbench");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;

const PipeBench = struct {
    pipeline: *Pipeline,
    arena: std.mem.Allocator,

    const Self = @This();

    fn init(p: *Pipeline, arena: std.mem.Allocator) Self {
        return .{ .pipeline = p, .arena = arena };
    }

    pub fn run(self: Self, _: std.mem.Allocator) void {
        // self.pipeline.rerouted = true;
        self.pipeline.dirty = true;
        self.pipeline.run(self.arena) catch unreachable;
    }
};

fn runPipeBench(allocator: std.mem.Allocator, arena: std.mem.Allocator, pipeline: *Pipeline) !void {
    const config: zbench.Config = .{
        // .iterations = 0,
        .max_iterations = 100,
        // .time_budget_ns = 1e9, // 1 second
    };
    var bench = zbench.Benchmark.init(allocator, config);
    defer bench.deinit();
    try bench.addParam("Pipeline Benchmark", &PipeBench.init(pipeline, arena), .{});

    var buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();
}

test "simple test modules" {
    const allocator = std.testing.allocator;

    // const aa = allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cp_out = pie.cli.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init();
    defer gpu_instance.deinit();

    const pipeline_config: pie.engine.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };

    var pipeline = Pipeline.init(allocator, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

    const mod_test_i_1234 = try pipeline.addModule(pie.engine.modules.test_i_1234.module);
    const mod_test_multiply = try pipeline.addModule(pie.engine.modules.test_multiply.module);
    const mod_test_2nodes = try pipeline.addModule(pie.engine.modules.test_2nodes.module);
    const mod_test_o_2468 = try pipeline.addModule(pie.engine.modules.test_o_2468.module);
    _ = try pipeline.addModule(pie.engine.modules.test_multiply.module); // dummy
    const mod_test_nop = try pipeline.addModule(pie.engine.modules.test_nop.module);

    pipeline.setModuleParam(mod_test_multiply, "multiplier", .{ .f32 = 2.0 }) catch unreachable;
    pipeline.setModuleParam(mod_test_multiply, "adder", .{ .i32 = 0 }) catch unreachable;

    pipeline.connectModulesName(mod_test_i_1234, "output", mod_test_multiply, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_multiply, "output", mod_test_2nodes, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_2nodes, "output", mod_test_nop, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_nop, "output", mod_test_o_2468, "input") catch unreachable;

    try pipeline.run(aa);
    // pipeline.rerouted = true;
    // pipeline.dirty = true;
    // try pipeline.run(aa);

    // try runPipeBench(allocator, aa, &pipeline);
}
