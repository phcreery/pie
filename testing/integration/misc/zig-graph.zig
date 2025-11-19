const std = @import("std");
const pie = @import("pie");
const builtin = @import("builtin");
const graph = pie.engine.graph;

const UTF8ConsoleOutput = struct {
    original: if (builtin.os.tag == .windows) c_uint else void,

    fn init() UTF8ConsoleOutput {
        if (builtin.os.tag == .windows) {
            const original = std.os.windows.kernel32.GetConsoleOutputCP();
            _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
            return .{ .original = original };
        }
        return .{ .original = {} };
    }

    fn deinit(self: UTF8ConsoleOutput) void {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.kernel32.SetConsoleOutputCP(self.original);
        }
    }
};

fn Lanes(TLane: type, n: usize) type {
    return struct {
        lanes: [n]?TLane = @splat(null),

        const Self = @This();

        /// consume removes the given value from the lanes and returns its index.
        fn consume(self: *Self, value: TLane) !usize {
            for (self.lanes, 0..) |lane, idx| {
                const l = lane orelse continue;
                if (l == value) {
                    self.lanes[idx] = null;
                    return idx;
                }
            }
            return error.NotFound;
        }

        /// add adds the given value to the first available lane and returns its index.
        fn add(self: *Self, value: TLane) !usize {
            for (self.lanes, 0..) |lane, idx| {
                if (lane == null) {
                    self.lanes[idx] = value;
                    return idx;
                }
            }
            return error.NoSpace;
        }
    };
}

test "dfs2" {
    const allocator = std.testing.allocator;
    const print = std.debug.print;
    const cp_out = UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    const TVertex = []const u8;
    const TEdge = u64;

    var g = graph.DirectedGraph(TVertex, TEdge, std.hash_map.StringContext).init(allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("B1");
    try g.add("B2");
    try g.add("B3");
    try g.add("C");
    try g.addEdge("A", "B1", 1);
    try g.addEdge("A", "B2", 2);
    try g.addEdge("A", "B3", 4);
    try g.addEdge("B1", "C", 3);
    try g.addEdge("B3", "C", 5);

    // DFS from B
    var list = std.ArrayList([]const u8).initCapacity(allocator, 4) catch unreachable;
    defer list.deinit(allocator);
    // var iter = try g.dfsIterator("A");
    // defer iter.deinit();
    var iter = try g.topSortIterator();
    defer iter.deinit();

    const MAX_LANES = 6;
    var conn_lanes = Lanes(TEdge, MAX_LANES){};
    var node_inputs: [MAX_LANES]?TEdge = @splat(null);
    var node_outputs: [MAX_LANES]?TEdge = @splat(null);
    var new_lanes: [MAX_LANES]?TEdge = @splat(null);

    while (try iter.next()) |value| {
        node_inputs = @splat(null);
        node_outputs = @splat(null);

        const vert = g.lookup(value).?;

        var node_in_edges = g.getInEdges(vert);
        defer node_in_edges.deinit(allocator);
        for (node_in_edges.items) |edge| {
            const idx = conn_lanes.consume(edge) catch continue;
            node_outputs[idx] = edge;
        }

        // print node inputs
        print("┌─", .{});
        for (0..MAX_LANES) |i| {
            if (node_outputs[i]) |_| {
                print("▼", .{});
            } else {
                print("─", .{});
            }
            print("──", .{});
        }
        print("─┐\n", .{});

        // print node name
        print("│ {s}", .{vert});
        // get length of vert for formatting
        var buffer: [50]u8 = undefined;
        const written_slice = try std.fmt.bufPrint(&buffer, "{s}", .{vert});
        for (0..3 * MAX_LANES - written_slice.len + 1) |_| {
            print(" ", .{});
        }
        print("│\n", .{});

        var out_edges = g.getOutEdges(vert);
        defer out_edges.deinit(allocator);
        for (out_edges.items) |edge| {
            const lane_idx = try conn_lanes.add(edge);
            new_lanes[lane_idx] = edge;
            node_inputs[lane_idx] = edge;
        }

        // print node outputs
        print("└─", .{});
        for (0..MAX_LANES) |i| {
            if (node_inputs[i]) |_| {
                print("▣", .{}); // ▼ ▣ △ ▲ ▽ ▼ ╤
            } else {
                print("─", .{});
            }
            print("──", .{});
        }
        print("─┘\n", .{});

        // print | for active lanes
        var r: usize = 0;
        outer: while (true) {
            r += 1;
            print(" ", .{});
            for (conn_lanes.lanes, 0..) |lane, i| {
                print(" ", .{});
                if (lane) |_| {
                    if (r % 2 == 0 and new_lanes[i] != null) {
                        new_lanes[i] = null;
                        print("├", .{});
                        // ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n
                        for (0..3 * (MAX_LANES - i)) |_| {
                            print("┄", .{});
                        }
                        print("\n", .{});
                        continue :outer;
                    }
                    print("│", .{});
                } else {
                    print(" ", .{});
                }
                print(" ", .{});
                // print(" ", .{});
            }
            print("\n", .{});
            // if there are no new lanes, break
            const all_empty: [MAX_LANES]?TEdge = @splat(null);
            if (std.mem.eql(?TEdge, &new_lanes, &all_empty)) {
                break;
            }
        }

        try list.append(g.allocator, vert);
        // for (iter.stack.items) |v| {
        //     print("stack: {s}\n", .{g.lookup(v).?});
        // }
    }
    // print("{any}\n", .{iter.post_order.items});
    // for (iter.post_order.items) |v| {
    //     print("Post-order: {s}\n", .{g.lookup(v).?});
    // }

    // const expect = [_][]const u8{ "B", "C2", "C3", "C", "A" };
    // const expect = [_][]const u8{ "B", "C2", "C1", "A", "C3" }; // incorrect
    // try std.testing.expectEqualSlices([]const u8, &expect, list.items);
}

test "topSortIterator" {
    const allocator = std.testing.allocator;
    const print = std.debug.print;
    const cp_out = UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    const TVertex = []const u8;
    const TEdge = u64;

    var g = graph.DirectedGraph(TVertex, TEdge, std.hash_map.StringContext).init(allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("B1");
    try g.add("B2");
    try g.add("B3");
    try g.add("C");
    try g.addEdge("A", "B1", 1);
    try g.addEdge("A", "B2", 2);
    try g.addEdge("A", "B3", 4);
    try g.addEdge("B1", "C", 3);
    try g.addEdge("B3", "C", 5);

    // DFS from B
    var list = std.ArrayList([]const u8).initCapacity(allocator, 4) catch unreachable;
    defer list.deinit(allocator);
    var iter = try g.topSortIterator();
    defer iter.deinit();
    while (try iter.next()) |value| {
        const vert = g.lookup(value).?;
        try list.append(g.allocator, vert);
        print("TopSort: {s}\n", .{vert});
    }
}
