const std = @import("std");
const pie = @import("pie");
const graph = pie.engine.graph;

// const Lanes = struct {
//     lanes: [100]?u64 = @splat(null),
// };

fn Lanes(TLane: type, n: usize) type {
    return struct {
        lanes: [n]?TLane = @splat(null),

        const Self = @This();

        fn consume(self: *Self, value: TLane) !usize {
            for (self.lanes, 0..) |lane, idx| {
                if (lane.? == value) {
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

    var lanes = Lanes(u64, 20){};
    while (try iter.next()) |value| {
        const vert = g.lookup(value).?;

        const in_edges = g.getInEdges(vert);
        var in_edges_idx = std.ArrayList(u8).initCapacity(allocator, 4) catch unreachable;
        for (in_edges.items) |edge| {
            lanes.consume(edge);
        }

        try list.append(g.allocator, vert);
    }

    const expect = [_][]const u8{ "B", "C2", "C3", "C", "A" };
    // std.debug.print("DFS2 result: {any}\n", .{list.items});
    // std.debug.print("DFS2 expect: {any}\n", .{expect});
    try std.testing.expectEqualSlices([]const u8, &expect, list.items);
}
