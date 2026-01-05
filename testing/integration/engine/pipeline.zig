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
    var mark = std.AutoHashMap(usize, u8).init(allocator);
    defer mark.deinit();

    var stack: [1000]usize = undefined; // Stack to hold node IDs
    var sp: isize = -1; // Stack pointer

    var node_pool_handles = node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        // const dst_node = node_pool.getPtr(node_handle) catch unreachable;
        try mark.put(node_handle.id, 0);
    }

    // Initialize stack with all nodes that have no dependencies (sink nodes)
    node_pool_handles = node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        const node = node_pool.getPtr(node_handle) catch unreachable;
        for (node.desc.sockets) |socket| {
            if (socket) |sock| {
                if (sock.type == .sink) {
                    sp += 1;
                    stack[@as(usize, @intCast(sp))] = node_handle.id;
                    try mark.put(node_handle.id, 1); // Mark as in-progress
                    break;
                }
            }
        }
    }

    while (sp >= 0) {
        const currId = stack[@as(usize, @intCast(sp))];
        // const currNode = findNode(nodes, currId) catch return;
        const currNode = node_pool.getPtr(pie.pipeline.NodeHandle{ .id = currId }) catch return;

        const currentMark = mark.getPtr(currId) orelse return;
        if (currentMark.* == 1) {
            // First time processing this node, push its children onto the stack
            try mark.put(currId, 2); // Pre-visit handling (mark as in-progress)
            for (currNode.desc.sockets) |child_socket| {
                const socket = child_socket orelse continue;
                // const connected_to_node = socket.private.connected_to_node orelse continue;
                const connected_to_node = pipeline.getConnectedNode(socket) orelse continue;
                const child_id = connected_to_node.item.id;
                const childMark = mark.getPtr(child_id) orelse return;
                if (childMark.* == 0) { // If child is unvisited
                    sp += 1;
                    if (sp >= stack.len) {
                        return error.StackOverflow;
                    }
                    stack[@as(usize, @intCast(sp))] = child_id;
                    try mark.put(child_id, 1); // Mark as in-progress
                }
            }
        } else {
            // All children have been processed, post-visit handling
            try mark.put(currId, 3); // Mark as finished
            // Process currNode here (e.g., print or store in result list)
            std.debug.print("Visited node ID: {d}\n", .{currId});
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
