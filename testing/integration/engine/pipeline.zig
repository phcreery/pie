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

pub fn traverseDAG(allocator: std.mem.Allocator, pipeline: *Pipeline, node_pool: *pie.pipeline.NodePool) !void {
    // Map from `id` to `mark` value
    var mark = std.AutoHashMap(pie.pipeline.NodeHandle, u8).init(allocator);
    defer mark.deinit();

    var stack: [1000]pie.pipeline.NodeHandle = undefined; // Stack to hold node IDs
    var sp: isize = -1; // Stack pointer

    var node_pool_handles = node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        try mark.put(node_handle, 0);
    }

    // Initialize stack with all nodes that have no dependencies (sink nodes)
    node_pool_handles = node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        const node = node_pool.getPtr(node_handle) catch unreachable;
        for (node.desc.sockets) |socket| {
            if (socket) |sock| {
                if (sock.type == .sink) {
                    sp += 1;
                    stack[@as(usize, @intCast(sp))] = node_handle;
                    try mark.put(node_handle, 1); // Mark as in-progress
                    break;
                }
            }
        }
    }

    while (sp >= 0) {
        const curr_handle = stack[@as(usize, @intCast(sp))];
        const curr_node = node_pool.getPtr(curr_handle) catch return;
        const curr_mark = mark.getPtr(curr_handle) orelse return;
        if (curr_mark.* == 1) {
            // First time processing this node, push its children onto the stack
            try mark.put(curr_handle, 2); // Pre-visit handling (mark as in-progress)
            for (curr_node.desc.sockets) |child_socket| {
                const socket = child_socket orelse continue;
                const connected_to_node = pipeline.getConnectedNode(socket) orelse continue;
                const child_node = connected_to_node.item;
                const child_mark = mark.getPtr(child_node) orelse return;
                if (child_mark.* == 0) { // If child is unvisited
                    sp += 1;
                    if (sp >= stack.len) {
                        return error.StackOverflow;
                    }
                    stack[@as(usize, @intCast(sp))] = child_node;
                    try mark.put(child_node, 1); // Mark as in-progress
                }
            }
        } else {
            // All children have been processed, post-visit handling
            try mark.put(curr_handle, 3); // Mark as finished
            // Process currNode here (e.g., print or store in result list)
            std.debug.print("Visited node: {any}\n", .{curr_handle});
            sp -= 1; // Pop the current node off the stack
        }
    }
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

    try pipeline.run();
    // pipeline.rerouted = true;
    // pipeline.dirty = true;
    // try pipeline.run();

    // try runPipeBench(allocator, &pipeline);

    traverseDAG(allocator, &pipeline, &pipeline.node_pool) catch unreachable;
}
