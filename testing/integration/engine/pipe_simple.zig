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

    var registry = try pie.engine.modules.Registry.init(allocator);
    defer registry.deinit();

    try pie.engine.modules.populateRegistry(&registry);

    const pipeline_config: pie.engine.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };

    var pipeline = Pipeline.init(allocator, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

    const mod_test_i_1234 = try pipeline.addModule(registry.get("test-i-1234").?);
    const mod_test_multiply = try pipeline.addModule(registry.get("test-multiply").?);
    const mod_test_2nodes = try pipeline.addModule(registry.get("test-2nodes").?);
    const mod_test_o_2468 = try pipeline.addModule(registry.get("test-o-2468").?);
    _ = try pipeline.addModule(registry.get("test-multiply").?); // dummy
    const mod_test_nop_1 = try pipeline.addModule(registry.get("test-nop").?);
    const mod_test_nop_2 = try pipeline.addModule(registry.get("test-nop").?);

    pipeline.setModuleParam(mod_test_multiply, "multiplier", .{ .f32 = 2.0 }) catch unreachable;
    pipeline.setModuleParam(mod_test_multiply, "adder", .{ .i32 = 0 }) catch unreachable;

    pipeline.connectModulesName(mod_test_i_1234, "output", mod_test_multiply, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_multiply, "output", mod_test_2nodes, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_2nodes, "output", mod_test_nop_1, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_nop_1, "output", mod_test_nop_2, "input") catch unreachable;
    pipeline.connectModulesName(mod_test_nop_2, "output", mod_test_o_2468, "input") catch unreachable;

    try pipeline.run(aa);
    // pipeline.rerouted = true;
    // pipeline.dirty = true;
    // try pipeline.run(aa);

    // try runPipeBench(allocator, aa, &pipeline);
}
