/// https://github.com/mitchellh/zig-graph
/// A directed graph implementation in Zig.
/// TODO: ASCII diagram of structure. (https://arxiv.org/pdf/1908.07544)
const std = @import("std");
const hash_map = std.hash_map;
const math = std.math;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const tarjan = @import("tarjan.zig");

pub const GraphError = error{
    VertexNotFoundError,
};

/// A directed graph that contains nodes of a given type.
///
/// The Context is the same as the Context for std.hash_map and must
/// provide for a hash function and equality function. This is used to
/// determine graph node equality.
pub fn DirectedGraph(
    comptime TVertex: type,
    comptime TEdge: type,
    comptime Context: type,
) type {
    // This verifies the context has the correct functions (hash and eql)
    // comptime hash_map.verifyContext(Context, T, T, u64, false); removed in https://github.com/ziglang/zig/pull/22370

    const VertexKey = u64;

    // The adjacency list type is used to map all edges in the graph.
    // The key is the source node. The value is a map where the key is
    // target node and the value is the edge weight.
    const AdjMapValue = hash_map.AutoHashMap(VertexKey, TEdge);
    const AdjMap = hash_map.AutoHashMap(VertexKey, AdjMapValue);

    // ValueMap maps hash codes to the actual value.
    const VertexMap = hash_map.AutoHashMap(VertexKey, TVertex);

    return struct {
        // allocator to use for all operations
        allocator: Allocator,

        // ctx is the context implementation
        ctx: Context,

        // adjacency lists for outbound and inbound edges and a map to
        // get the real value.
        adj_out: AdjMap,
        adj_in: AdjMap,
        vertices: VertexMap,

        const Self = @This();

        /// Size is the maximum size (as a type) that the graph can hold.
        /// This is currently dictated by our usage of HashMap underneath.
        const Size = AdjMap.Size;

        /// initialize a new directed graph. This is used if the Context type
        /// has no data (zero-sized).
        pub fn init(allocator: Allocator) Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Context is non-zero sized. Use initContext instead.");
            }

            return initContext(allocator, undefined);
        }

        /// same as init but for non-zero-sized contexts.
        pub fn initContext(allocator: Allocator, ctx: Context) Self {
            return .{
                .allocator = allocator,
                .ctx = ctx,
                .adj_out = AdjMap.init(allocator),
                .adj_in = AdjMap.init(allocator),
                .vertices = VertexMap.init(allocator),
            };
        }
        /// deinitialize all the memory associated with the graph. If you
        /// deinitialize the allocator used with this graph you don't need to
        /// call this.
        pub fn deinit(self: *Self) void {
            // Free values for our adj maps
            var it = self.adj_out.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.deinit();
            }
            it = self.adj_in.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.deinit();
            }

            self.adj_out.deinit();
            self.adj_in.deinit();
            self.vertices.deinit();
            self.* = undefined;
        }

        /// Add a node to the graph.
        pub fn add(self: *Self, v: TVertex) !void {
            const k = self.ctx.hash(v);

            // If we already have this node, then do nothing.
            if (self.adj_out.contains(k)) {
                return;
            }

            try self.adj_out.put(k, AdjMapValue.init(self.allocator));
            try self.adj_in.put(k, AdjMapValue.init(self.allocator));
            try self.vertices.put(k, v);
        }

        /// Remove a node and all edges to and from the node.
        pub fn remove(self: *Self, v: TVertex) void {
            const k = self.ctx.hash(v);

            // Forget this value
            _ = self.vertices.remove(k);

            // Delete in-edges for this vertex.
            if (self.adj_out.getPtr(k)) |map| {
                var it = map.iterator();
                while (it.next()) |kv| {
                    if (self.adj_in.getPtr(kv.key_ptr.*)) |inMap| {
                        _ = inMap.remove(k);
                    }
                }

                map.deinit();
                _ = self.adj_out.remove(k);
            }

            // Delete out-edges for this vertex
            if (self.adj_in.getPtr(k)) |map| {
                var it = map.iterator();
                while (it.next()) |kv| {
                    if (self.adj_out.getPtr(kv.key_ptr.*)) |inMap| {
                        _ = inMap.remove(k);
                    }
                }

                map.deinit();
                _ = self.adj_in.remove(k);
            }
        }

        /// contains returns true if the graph has the given vertex.
        pub fn contains(self: *Self, v: TVertex) bool {
            return self.vertices.contains(self.ctx.hash(v));
        }

        /// lookup looks up a vertex by hash. The hash is often used
        /// as a result of algorithms such as strongly connected components
        /// since it is easier to work with. This function can be called to
        /// get the real value.
        pub fn lookup(self: *const Self, hash: VertexKey) ?TVertex {
            return self.vertices.get(hash);
        }

        /// add an edge from one node to another. This will return an
        /// error if either vertex does not exist.
        pub fn addEdge(self: *Self, from: TVertex, to: TVertex, edge: TEdge) !void {
            const k_from = self.ctx.hash(from);
            const k_to = self.ctx.hash(to);

            const map_out = self.adj_out.getPtr(k_from) orelse
                return GraphError.VertexNotFoundError;
            const map_in = self.adj_in.getPtr(k_to) orelse
                return GraphError.VertexNotFoundError;

            try map_out.put(k_to, edge);
            try map_in.put(k_from, edge);
        }

        /// remove an edge
        pub fn removeEdge(self: *Self, from: TVertex, to: TVertex) void {
            const k_from = self.ctx.hash(from);
            const k_to = self.ctx.hash(to);

            if (self.adj_out.getPtr(k_from)) |map| {
                _ = map.remove(k_to);
            }

            if (self.adj_in.getPtr(k_to)) |map| {
                _ = map.remove(k_from);
            }
        }

        /// getEdge gets the edge from one node to another and returns the
        /// weight, if it exists.
        pub fn getEdge(self: *const Self, from: TVertex, to: TVertex) ?TEdge {
            const k_from = self.ctx.hash(from);
            const k_to = self.ctx.hash(to);

            if (self.adj_out.getPtr(k_from)) |map| {
                return map.get(k_to);
            } else {
                return null;
            }
        }

        // reverse reverses the graph. This does NOT make any copies, so
        // any changes to the original affect the reverse and vice versa.
        // Likewise, only one of these graphs should be deinitialized.
        pub fn reverse(self: *const Self) Self {
            return Self{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .adj_out = self.adj_in,
                .adj_in = self.adj_out,
                .vertices = self.vertices,
            };
        }

        /// Create a copy of this graph using the same allocator.
        pub fn clone(self: *const Self) !Self {
            return Self{
                .allocator = self.allocator,
                .ctx = self.ctx,
                .adj_out = try cloneAdjMap(&self.adj_out),
                .adj_in = try cloneAdjMap(&self.adj_in),
                .vertices = try self.vertices.clone(),
            };
        }

        /// clone our AdjMap including inner values.
        fn cloneAdjMap(m: *const AdjMap) !AdjMap {
            // Clone the outer container
            var new = try m.clone();

            // Clone all objects
            var it = new.iterator();
            while (it.next()) |kv| {
                try new.put(kv.key_ptr.*, try kv.value_ptr.clone());
            }

            return new;
        }

        /// The number of vertices in the graph.
        pub fn countVertices(self: *const Self) Size {
            return self.vertices.count();
        }

        /// The number of edges in the graph.
        ///
        /// O(V) where V is the # of vertices. We could cache this if we
        /// wanted but its not a very common operation.
        pub fn countEdges(self: *const Self) Size {
            var count: Size = 0;
            var it = self.adj_out.iterator();
            while (it.next()) |kv| {
                count += kv.value_ptr.count();
            }

            return count;
        }

        /// getEdges returns all edges connected to the given vertex.
        pub fn getEdges(self: *const Self, vertex: TVertex) std.ArrayList(TEdge) {
            const k = self.ctx.hash(vertex);
            var edges = std.ArrayList(TEdge).initCapacity(self.allocator, 0) catch unreachable;
            // defer edges.deinit(self.allocator);

            if (self.adj_out.getPtr(k)) |map| {
                var iter = map.iterator();
                // var iter = map.keyIterator();
                while (iter.next()) |kv| {
                    edges.append(self.allocator, kv.value_ptr.*) catch unreachable;
                }
            }
            if (self.adj_in.getPtr(k)) |in_map| {
                var in_iter = in_map.iterator();
                while (in_iter.next()) |kv| {
                    edges.append(self.allocator, kv.value_ptr.*) catch unreachable;
                }
            }
            return edges;
        }

        /// getOutEdges returns all outbound edges from the given vertex.
        pub fn getOutEdges(self: *const Self, vertex: TVertex) std.ArrayList(TEdge) {
            const k = self.ctx.hash(vertex);
            var edges = std.ArrayList(TEdge).initCapacity(self.allocator, 0) catch unreachable;
            // defer edges.deinit(self.allocator);

            if (self.adj_out.getPtr(k)) |map| {
                var iter = map.iterator();
                while (iter.next()) |kv| {
                    edges.append(self.allocator, kv.value_ptr.*) catch unreachable;
                }
            }
            return edges;
        }

        /// getInEdges returns all inbound edges to the given vertex.
        pub fn getInEdges(self: *const Self, vertex: TVertex) std.ArrayList(TEdge) {
            const k = self.ctx.hash(vertex);
            var edges = std.ArrayList(TEdge).initCapacity(self.allocator, 0) catch unreachable;
            // defer edges.deinit(self.allocator);

            if (self.adj_in.getPtr(k)) |map| {
                var iter = map.iterator();
                while (iter.next()) |kv| {
                    edges.append(self.allocator, kv.value_ptr.*) catch unreachable;
                }
            }
            return edges;
        }

        /// Cycles returns the set of cycles (if any).
        pub fn cycles(
            self: *const Self,
        ) ?tarjan.StronglyConnectedComponents {
            var sccs = self.stronglyConnectedComponents();
            var i: usize = 0;
            while (i < sccs.list.items.len) {
                const current = sccs.list.items[i];
                if (current.items.len <= 1) {
                    var old = sccs.list.swapRemove(i);
                    old.deinit(self.allocator);
                    continue;
                }

                i += 1;
            }

            if (sccs.list.items.len == 0) {
                sccs.deinit();
                return null;
            }

            return sccs;
        }

        /// Returns the set of strongly connected components in this graph.
        /// This allocates memory.
        pub fn stronglyConnectedComponents(
            self: *const Self,
        ) tarjan.StronglyConnectedComponents {
            return tarjan.stronglyConnectedComponents(self.allocator, self);
        }

        /// dfsIterator returns an iterator that iterates all reachable
        /// vertices from "start". Note that the DFSIterator must have
        /// deinit called. It is an error if start does not exist.
        pub fn dfsIterator(self: *const Self, start: TVertex) !DFSIterator {
            const h = self.ctx.hash(start);

            // Start must exist
            if (!self.vertices.contains(h)) {
                return GraphError.VertexNotFoundError;
            }

            // We could pre-allocate some space here and assume we'll visit
            // the full graph or something. Keeping it simple for now.
            const stack = std.ArrayList(VertexKey).initCapacity(self.allocator, 0) catch unreachable;
            const visited = std.AutoHashMap(VertexKey, void).init(self.allocator);
            const post_order = std.ArrayList(VertexKey).initCapacity(self.allocator, 0) catch unreachable;

            return DFSIterator{
                .g = self,
                .stack = stack,
                .visited = visited,
                .current_vert = h,
                .post_order = post_order,
            };
        }

        pub const DFSIterator = struct {
            // Not the most efficient data structures for this, I know,
            // but we can come back and optimize this later since its opaque.
            //
            // stack and visited must ensure capacity
            g: *const Self,
            stack: std.ArrayList(VertexKey),
            post_order: std.ArrayList(VertexKey),
            visited: std.AutoHashMap(VertexKey, void),
            current_vert: ?VertexKey,

            // DFSIterator must deinit
            pub fn deinit(it: *DFSIterator) void {
                it.stack.deinit(it.g.allocator);
                it.visited.deinit();
                it.post_order.deinit(it.g.allocator);
            }

            /// next returns the list of hash IDs for the vertex. This should be
            /// looked up again with the graph to get the actual vertex value.
            pub fn next(it: *DFSIterator) !?VertexKey {
                // If we're out of values, then we're done.
                if (it.current_vert == null) return null;

                // Our result is our current value
                const result_vert = it.current_vert orelse unreachable;
                try it.visited.put(result_vert, {});

                // Add all adjacent edges to the stack. We do a
                // visited check here to avoid revisiting vertices
                if (it.g.adj_out.getPtr(result_vert)) |map| {
                    var iter = map.keyIterator();
                    while (iter.next()) |vert| {
                        if (!it.visited.contains(vert.*)) {
                            try it.stack.append(it.g.allocator, vert.*);
                        }
                    }
                }
                // for (it.stack.items) |v| {
                //     std.debug.print("stack: {s}\n", .{it.g.lookup(v).?});
                // }

                // Advance to the next value
                it.current_vert = null;
                while (it.stack.pop()) |next_vert| {
                    // std.debug.print("popping: {s}\n", .{it.g.lookup(next_vert).?});
                    if (!it.visited.contains(next_vert)) {
                        // try it.post_order.append(it.g.allocator, next_vert);
                        it.current_vert = next_vert;
                        break;
                    }
                }

                return result_vert;
            }
        };

        pub fn topSortIterator(self: *const Self) !TopSortIterator {
            // Compute in-degrees
            var in_degree = std.AutoHashMap(VertexKey, usize).init(self.allocator);
            var it = self.adj_out.iterator();
            while (it.next()) |kv| {
                const from = kv.key_ptr.*;
                if (!in_degree.contains(from)) {
                    try in_degree.put(from, 0);
                }

                var neighbors = kv.value_ptr.iterator();
                while (neighbors.next()) |n_kv| {
                    const to = n_kv.key_ptr.*;
                    const deg_ptr = in_degree.getPtr(to);
                    if (deg_ptr) |deg| {
                        deg.* += 1;
                    } else {
                        try in_degree.put(to, 1);
                    }
                }
            }

            // Initialize queue with all nodes with in-degree 0
            var queue = std.ArrayList(VertexKey).initCapacity(self.allocator, 0) catch unreachable;
            var deg_it = in_degree.iterator();
            while (deg_it.next()) |kv| {
                if (kv.value_ptr.* == 0) {
                    try queue.append(self.allocator, kv.key_ptr.*);
                }
            }

            return TopSortIterator{
                .g = self,
                .queue = queue,
                .in_degree = in_degree,
            };
        }

        /// non recursive topological sort iterator
        /// using Kahn's algorithm
        pub const TopSortIterator = struct {
            g: *const Self,
            queue: std.ArrayList(VertexKey),
            in_degree: std.AutoHashMap(VertexKey, usize),

            pub fn deinit(it: *TopSortIterator) void {
                it.queue.deinit(it.g.allocator);
                it.in_degree.deinit();
            }

            pub fn next(it: *TopSortIterator) !?VertexKey {
                if (it.queue.items.len == 0) {
                    return null;
                }

                const v = it.queue.pop() orelse unreachable;

                // Decrease in-degree of all neighbors
                if (it.g.adj_out.getPtr(v)) |map| {
                    var iter = map.keyIterator();
                    while (iter.next()) |neighbor| {
                        const deg = it.in_degree.getPtr(neighbor.*) orelse continue;
                        deg.* -= 1;
                        if (deg.* == 0) {
                            try it.queue.append(it.g.allocator, neighbor.*);
                        }
                    }
                }

                return v;
            }
        };
    };
}

test "add and remove vertex" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // No vertex
    try testing.expect(!g.contains("A"));

    // Add some nodes
    try g.add("A");
    try g.add("A");
    try g.add("B");
    try testing.expect(g.contains("A"));
    try testing.expect(g.countVertices() == 2);
    try testing.expect(g.countEdges() == 0);

    // add an edge
    try g.addEdge("A", "B", 1);
    try testing.expect(g.countEdges() == 1);

    // Remove a node
    g.remove("A");
    try testing.expect(g.countVertices() == 1);

    // important: removing a node should remove the edge
    try testing.expect(g.countEdges() == 0);
}

test "add and remove edge" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("A");
    try g.add("B");

    // add an edge
    try g.addEdge("A", "B", 1);
    try g.addEdge("A", "B", 4);
    try testing.expect(g.countEdges() == 1);
    try testing.expect(g.getEdge("A", "B").? == 4);

    // Remove the node
    g.removeEdge("A", "B");
    g.removeEdge("A", "B");
    try testing.expect(g.countEdges() == 0);
    try testing.expect(g.countVertices() == 2);
}

test "reverse" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("B");
    try g.addEdge("A", "B", 1);

    // Reverse
    const rev = g.reverse();

    // Should have the same number
    try testing.expect(rev.countEdges() == 1);
    try testing.expect(rev.countVertices() == 2);
    try testing.expect(rev.getEdge("A", "B") == null);
    try testing.expect(rev.getEdge("B", "A").? == 1);
}

test "clone" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");

    // Clone
    var g2 = try g.clone();
    defer g2.deinit();

    try g.add("B");
    try testing.expect(g.contains("B"));
    try testing.expect(!g2.contains("B"));
}

test "cycles and strongly connected components" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    var alone = g.stronglyConnectedComponents();
    defer alone.deinit();
    const value = g.lookup(alone.list.items[0].items[0]);
    try testing.expectEqual(value.?, "A");

    // Add more
    try g.add("B");
    try g.addEdge("A", "B", 1);
    var sccs = g.stronglyConnectedComponents();
    defer sccs.deinit();
    try testing.expect(sccs.count() == 2);
    try testing.expect(g.cycles() == null);

    // Add a cycle
    try g.addEdge("B", "A", 1);
    var sccs2 = g.stronglyConnectedComponents();
    defer sccs2.deinit();
    try testing.expect(sccs2.count() == 1);

    // Should have a cycle
    var cycles = g.cycles() orelse unreachable;
    defer cycles.deinit();
    try testing.expect(cycles.count() == 1);
}

test "dfs" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("B");
    try g.add("C");
    try g.addEdge("B", "C", 1);
    try g.addEdge("C", "A", 1);

    // DFS from A should only reach A
    {
        var list = std.ArrayList([]const u8).initCapacity(testing.allocator, 4) catch unreachable;
        defer list.deinit(testing.allocator);
        var iter = try g.dfsIterator("A");
        defer iter.deinit();
        while (try iter.next()) |value| {
            try list.append(g.allocator, g.lookup(value).?);
        }

        const expect = [_][]const u8{"A"};
        try testing.expectEqualSlices([]const u8, list.items, &expect);
    }

    // DFS from B
    {
        var list = std.ArrayList([]const u8).initCapacity(testing.allocator, 4) catch unreachable;
        defer list.deinit(testing.allocator);
        var iter = try g.dfsIterator("B");
        defer iter.deinit();
        while (try iter.next()) |value| {
            try list.append(g.allocator, g.lookup(value).?);
        }

        const expect = [_][]const u8{ "B", "C", "A" };
        try testing.expectEqualSlices([]const u8, &expect, list.items);
    }
}

test "dfs2" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // Add some nodes
    try g.add("A");
    try g.add("B");
    try g.add("C");
    try g.add("C2");
    try g.add("C3");
    try g.addEdge("B", "C", 1);
    try g.addEdge("B", "C2", 1);
    try g.addEdge("C", "A", 1);
    try g.addEdge("B", "C3", 1);

    // DFS from B
    {
        var list = std.ArrayList([]const u8).initCapacity(testing.allocator, 4) catch unreachable;
        defer list.deinit(testing.allocator);
        var iter = try g.dfsIterator("B");
        defer iter.deinit();
        while (try iter.next()) |value| {
            try list.append(g.allocator, g.lookup(value).?);
        }

        const expect = [_][]const u8{ "B", "C2", "C3", "C", "A" };
        // std.debug.print("DFS2 result: {any}\n", .{list.items});
        // std.debug.print("DFS2 expect: {any}\n", .{expect});
        try testing.expectEqualSlices([]const u8, &expect, list.items);
    }
}

test "get edges" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // B -> C  -> A
    //   -> C2
    //   -> C3

    // Add some nodes
    try g.add("A");
    try g.add("B");
    try g.add("C");
    try g.add("C2");
    try g.add("C3");
    try g.addEdge("B", "C", 1);
    try g.addEdge("B", "C2", 1);
    try g.addEdge("C", "A", 1);
    try g.addEdge("B", "C3", 1);

    var edges_b = g.getEdges("B");
    defer edges_b.deinit(testing.allocator);
    try testing.expectEqual(edges_b.items.len, 3);
    // std.debug.print("Edges B: {any}\n", .{edges_b.items});

    var edges_a = g.getEdges("A");
    defer edges_a.deinit(testing.allocator);
    try testing.expectEqual(edges_a.items.len, 1);
    // std.debug.print("Edges A: {any}\n", .{edges_a.items});
}

test "double edges" {
    const gtype = DirectedGraph([]const u8, u64, std.hash_map.StringContext);
    var g = gtype.init(testing.allocator);
    defer g.deinit();

    // B -> C  -> A
    //   -> C2 ->

    // Add some nodes
    try g.add("A");
    try g.add("B");
    try g.add("C");
    try g.add("C2");
    try g.addEdge("B", "C", 1);
    try g.addEdge("B", "C2", 2);
    try g.addEdge("C", "A", 3);
    try g.addEdge("C2", "A", 4);

    var edges_b = g.getEdges("B");
    defer edges_b.deinit(testing.allocator);
    try testing.expectEqual(edges_b.items.len, 2);
    // std.debug.print("Edges B: {any}\n", .{edges_b.items});

    const expect_b = [_]u64{ 1, 2 };
    try testing.expectEqualSlices(u64, &expect_b, edges_b.items);

    var edges_a = g.getEdges("A");
    defer edges_a.deinit(testing.allocator);
    try testing.expectEqual(edges_a.items.len, 2);
    // std.debug.print("Edges A: {any}\n", .{edges_a.items});
    const expect_a = [_]u64{ 3, 4 };
    try testing.expectEqualSlices(u64, &expect_a, edges_a.items);
}

test {
    _ = tarjan;
}
