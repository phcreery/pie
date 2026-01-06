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

/// stack-based DFS iterator for traversing DAGs stored in a HashMapPool
/// each element T must have a `desc` field in which there is a `sockets` field
/// each socket must have a `private.connected_to_node` field which is an optional connection to another node handle
pub fn PooledDagDfsIterator(allocator: std.mem.Allocator, T: type) type {
    return struct {
        pub fn iterator(node_pool: *pie.engine.HashMapPool(T)) !DAGDFSIterator {
            // Map from `id` to `mark` value
            var mark = std.AutoHashMap(pie.engine.HashMapPool(T).Handle, u8).init(allocator);
            errdefer mark.deinit();

            // Stack to hold node IDs
            var stack = try std.ArrayList(pie.engine.HashMapPool(T).Handle).initCapacity(allocator, 1024);
            errdefer stack.deinit(allocator);
            var sp: isize = -1; // Stack pointer

            // Initialize mark map
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
                            try stack.insert(allocator, @as(usize, @intCast(sp)), node_handle);
                            try mark.put(node_handle, 1); // Mark as in-progress
                            break;
                        }
                    }
                }
            }

            return DAGDFSIterator{
                .allocator = allocator,
                .stack = stack,
                .sp = sp,
                .mark = mark,
                .node_pool = node_pool,
            };
        }

        /// same as traverseDAG but iterative
        const DAGDFSIterator = struct {
            allocator: std.mem.Allocator,
            stack: std.ArrayList(pie.engine.HashMapPool(T).Handle),
            sp: isize,
            mark: std.AutoHashMap(pie.engine.HashMapPool(T).Handle, u8),
            node_pool: *pie.engine.HashMapPool(T),

            // DAGDFSIterator must deinit
            pub fn deinit(it: *DAGDFSIterator) void {
                it.stack.deinit(it.allocator);
                it.mark.deinit();
            }

            pub fn next(it: *DAGDFSIterator) !?pie.engine.HashMapPool(T).Handle {
                if (it.sp < 0) {
                    return null;
                }
                while (it.sp >= 0) {
                    const curr_handle = it.stack.items[@as(usize, @intCast(it.sp))];
                    const curr_node = try it.node_pool.getPtr(curr_handle);
                    const curr_mark = it.mark.getPtr(curr_handle) orelse return error.Unreachable;
                    if (curr_mark.* == 1) {
                        // First time processing this node, push its children onto the stack
                        try it.mark.put(curr_handle, 2); // Pre-visit handling (mark as in-progress)
                        for (curr_node.desc.sockets) |child_socket| {
                            const socket = child_socket orelse continue;
                            // const connected_to_node = pipeline.getConnectedNode(socket) orelse continue;
                            // const connected_to_node = socket.private.connected_to_node orelse continue;
                            const maybe_connected_to = if (comptime T == pie.engine.Node) socket.private.connected_to_node else if (comptime T == pie.engine.Module) socket.private.connected_to_module else unreachable;
                            const connected_to = maybe_connected_to orelse continue;
                            const child_node = connected_to.item;
                            const child_mark = it.mark.getPtr(child_node) orelse return error.Unreachable;
                            if (child_mark.* == 0) { // If child is unvisited
                                it.sp += 1;
                                try it.stack.insert(it.allocator, @as(usize, @intCast(it.sp)), child_node);
                                try it.mark.put(child_node, 1); // Mark as in-progress
                            }
                        }
                    } else {
                        // All children have been processed, post-visit handling
                        try it.mark.put(curr_handle, 3); // Mark as finished
                        it.sp -= 1; // Pop the current node off the stack
                        // Process currNode here (e.g., print or store in result list)
                        return curr_handle;
                    }
                }
                return null;
            }
        };
    };
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

    var module_dag_iter = try PooledDagDfsIterator(allocator, pie.engine.Module).iterator(&pipeline.module_pool);
    defer module_dag_iter.deinit();
    while (module_dag_iter.next()) |maybe_node_handle| {
        const node_handle = maybe_node_handle orelse break;
        std.debug.print("DAG DFS Visited module: {any}\n", .{node_handle});
    } else |err| {
        std.debug.print("Error during DAG traversal: {any}\n", .{err});
    }

    var node_dag_iter = try PooledDagDfsIterator(allocator, pie.engine.Node).iterator(&pipeline.node_pool);
    defer node_dag_iter.deinit();
    while (node_dag_iter.next()) |maybe_node_handle| {
        const node_handle = maybe_node_handle orelse break;
        std.debug.print("DAG DFS Visited node: {any}\n", .{node_handle});
    } else |err| {
        std.debug.print("Error during DAG traversal: {any}\n", .{err});
    }
}
