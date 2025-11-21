const std = @import("std");
const pie = @import("pie");
const graph = @import("graph.zig");

fn Lanes(TLane: type, n: usize) type {
    return struct {
        lanes: [n]?TLane = @splat(null),

        const Self = @This();

        /// consume removes the given value from the lanes and returns its index.
        fn consume(self: *Self, value: TLane) !usize {
            for (self.lanes, 0..) |lane, idx| {
                const l = lane orelse continue;
                if (std.meta.eql(l, value)) {
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

pub fn GraphPrinter(
    comptime TVertex: type,
    comptime TEdge: type,
    Context: type,
    edgePrinterCb: fn (buf: []u8, edge: TEdge, user_data: *anyopaque) []u8,
    vertPrinterCb: fn (buf: []u8, vertex: TVertex, user_data: *anyopaque) []u8,
) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        g: *graph.DirectedGraph(TVertex, TEdge, Context),
        user_data: *anyopaque,

        pub fn init(
            allocator: std.mem.Allocator,
            g: *graph.DirectedGraph(TVertex, TEdge, Context),
            user_data: *anyopaque,
        ) Self {
            return .{
                .allocator = allocator,
                .g = g,
                .user_data = user_data,
            };
        }

        pub fn print(
            self: *Self,
            writer: *std.Io.Writer,
            iter: anytype,
        ) !void {
            const MAX_LANES = 10;
            var edge_lanes = Lanes(TEdge, MAX_LANES){};
            var vert_inputs: [MAX_LANES]?TEdge = @splat(null);
            var vert_outputs: [MAX_LANES]?TEdge = @splat(null);
            var new_lanes: [MAX_LANES]?TEdge = @splat(null);

            while (try iter.next()) |value| {
                vert_inputs = @splat(null);
                vert_outputs = @splat(null);

                const vert = self.g.lookup(value).?;

                var vert_in_edges = self.g.getInEdges(vert);
                defer vert_in_edges.deinit(self.allocator);
                for (vert_in_edges.items) |edge| {
                    const idx = edge_lanes.consume(edge) catch continue;
                    vert_outputs[idx] = edge;
                }

                // print node inputs
                try writer.print("┌─", .{});
                for (0..MAX_LANES) |i| {
                    if (vert_outputs[i]) |_| {
                        try writer.print("▼", .{});
                    } else {
                        try writer.print("─", .{});
                    }
                    try writer.print("──", .{});
                }
                try writer.print("─┐\n", .{});

                // print node name
                // get length of vert for formatting
                var vert_name_print_buffer: [MAX_LANES * 3]u8 = undefined;
                const vert_name_slice = vertPrinterCb(&vert_name_print_buffer, vert, self.user_data);
                try writer.print("│ ", .{});
                try writer.print("{s}", .{vert_name_slice});
                const num_spaces: isize = 3 * @as(isize, @intCast(MAX_LANES)) - @as(isize, @intCast(vert_name_slice.len)) + 1;
                if (num_spaces > 0) {
                    for (0..@intCast(num_spaces)) |_| {
                        try writer.print(" ", .{});
                    }
                }
                try writer.print("│\n", .{});

                var out_edges = self.g.getOutEdges(vert);
                defer out_edges.deinit(self.allocator);
                for (out_edges.items) |edge| {
                    const lane_idx = try edge_lanes.add(edge);
                    new_lanes[lane_idx] = edge;
                    vert_inputs[lane_idx] = edge;
                }

                // print node outputs
                try writer.print("└─", .{});
                for (0..MAX_LANES) |i| {
                    if (vert_inputs[i]) |_| {
                        try writer.print("▼", .{}); // ▼ ▣ △ ▲ ▽ ▼ ╤
                    } else {
                        try writer.print("─", .{});
                    }
                    try writer.print("──", .{});
                }
                try writer.print("─┘\n", .{});

                // print | for active lanes
                var r: usize = 0;
                outer: while (true) {
                    r += 1;
                    try writer.print(" ", .{});
                    for (edge_lanes.lanes, 0..) |lane, i| {
                        try writer.print(" ", .{});
                        if (lane) |_| {
                            if (r % 2 == 0 and new_lanes[i] != null) {
                                new_lanes[i] = null;
                                try writer.print("├", .{});
                                // ├┄┄┄┄┄┄┄┄┄┄┄┄ {name}\n
                                var edge_name_print_buffer: [MAX_LANES * 3]u8 = undefined;
                                const edge_name_slice = edgePrinterCb(&edge_name_print_buffer, lane.?, self.user_data);
                                const num_dashes: isize = 3 * @as(isize, @intCast(MAX_LANES - i)) - @as(isize, @intCast(edge_name_slice.len)) - 1;
                                if (num_dashes > 0) {
                                    for (0..@intCast(num_dashes)) |_| {
                                        try writer.print("┄", .{});
                                    }
                                }
                                try writer.print(" {s}", .{edge_name_slice});
                                try writer.print("\n", .{});
                                continue :outer;
                            }
                            try writer.print("│", .{});
                        } else {
                            try writer.print(" ", .{});
                        }
                        try writer.print(" ", .{});
                        // try stdout.print(" ", .{});
                    }
                    try writer.print("\n", .{});
                    // if there are no new lanes, break
                    const all_empty: [MAX_LANES]?TEdge = @splat(null);
                    if (std.meta.eql(new_lanes, all_empty)) {
                        break;
                    }
                }

                // try list.append(g.allocator, vert);
            }
        }
    };
}

test "graph printer" {
    const allocator = std.testing.allocator;

    // to print to stdout
    // var stdout_buffer: [4096]u8 = undefined;
    // var writer = std.fs.File.stdout().writer(&stdout_buffer);
    // const stdout = &writer.interface;

    // to print to allocating buffer
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var stdout = &aw.writer;

    const cp_out = pie.cli.console.UTF8ConsoleOutput.init();
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
    try g.addEdge("B3", "C", 55);

    var iter1 = try g.topSortIterator();
    defer iter1.deinit();

    var printer = GraphPrinter(TVertex, TEdge).init(allocator, &g);
    try printer.print(stdout, &iter1);

    // test modifying graph and reprinting
    try g.add("D");
    try g.addEdge("C", "D", 9);

    var iter2 = try g.topSortIterator();
    defer iter2.deinit();
    try printer.print(stdout, &iter2);

    var found = false;
    var needle: u8 = 'D';
    var haystack = stdout.buffer;
    for (haystack) |straw| {
        if (straw == needle) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    found = false;
    needle = '9';
    haystack = stdout.buffer;
    for (haystack) |straw| {
        if (straw == needle) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    try stdout.flush(); // Don't forget to flush!
}
