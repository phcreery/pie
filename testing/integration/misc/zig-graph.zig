const std = @import("std");
const pie = @import("pie");
const graph = pie.engine.graph;

fn Lanes(TLane: type, n: usize) type {
    return struct {
        lanes: [n]?TLane = @splat(null),

        const Self = @This();

        fn consume(self: *Self, value: TLane) !usize {
            for (self.lanes, 0..) |lane, idx| {
                if (lane.? == value) {
                    self.lanes[idx] = null;
                    return idx;
                }
            }
            return error.NotFound;
        }

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

    const gtype = graph.DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("B");
    try g.add("C");
    try g.add("C2");
    try g.add("C3");
    try g.addEdge("B", "C", 1);
    try g.addEdge("B", "C2", 2);
    try g.addEdge("C", "A", 3);
    try g.addEdge("B", "C3", 4);

    // DFS from B
    var list = std.ArrayList([]const u8).initCapacity(allocator, 4) catch unreachable;
    defer list.deinit(allocator);
    var iter = try g.dfsIterator("B");
    defer iter.deinit();

    const MAX_LANES = 10;
    var lanes = Lanes(u64, MAX_LANES){};
    while (try iter.next()) |value| {
        const vert = g.lookup(value).?;

        var in_edges = g.getInEdges(vert);
        defer in_edges.deinit(allocator);
        var in_edges_idx = std.ArrayList(usize).initCapacity(allocator, 4) catch unreachable;
        defer in_edges_idx.deinit(allocator);
        for (in_edges.items) |edge| {
            const lane_idx = lanes.consume(edge) catch continue;
            in_edges_idx.append(allocator, lane_idx) catch unreachable;
        }

        // print I if there is an in_edge in lane
        print("┌", .{});
        for (0..MAX_LANES) |i| {
            print("─", .{});
            var found = false;
            for (in_edges_idx.items) |idx| {
                if (idx == i) {
                    found = true;
                    break;
                }
            }
            if (found) {
                print("▼", .{});
            } else {
                print("─", .{});
            }
            print("─", .{});
            // print("─", .{});
        }
        print("\n", .{});

        // print node name
        print("│ {s}\n", .{vert});

        var out_edges = g.getOutEdges(vert);
        defer out_edges.deinit(allocator);
        var out_edges_idx = std.ArrayList(usize).initCapacity(allocator, 4) catch unreachable;
        defer out_edges_idx.deinit(allocator);
        for (out_edges.items) |edge| {
            const lane_idx = try lanes.add(edge);
            out_edges_idx.append(allocator, lane_idx) catch unreachable;
        }

        print("└", .{});
        // print O for there is an out_edge in lane
        for (0..MAX_LANES) |i| {
            print("─", .{});
            var found = false;
            for (out_edges_idx.items) |idx| {
                if (idx == i) {
                    found = true;
                    break;
                }
            }
            if (found) {
                print("▣", .{}); // ▼ ▣ △ ▲ ▽ ▼ ╤
            } else {
                print("─", .{});
            }
            print("─", .{});
            // print("─", .{});
        }
        print("\n", .{});

        // print | for active lanes
        for (0..3) |_| {
            print(" ", .{});
            for (lanes.lanes) |lane| {
                print(" ", .{});
                if (lane) |_| {
                    print("│", .{});
                } else {
                    print(" ", .{});
                }
                print(" ", .{});
                // print(" ", .{});
            }
            print("\n", .{});
        }

        try list.append(g.allocator, vert);
    }

    const expect = [_][]const u8{ "B", "C2", "C3", "C", "A" };
    // std.debug.print("DFS2 result: {any}\n", .{list.items});
    // std.debug.print("DFS2 expect: {any}\n", .{expect});
    try std.testing.expectEqualSlices([]const u8, &expect, list.items);
}
