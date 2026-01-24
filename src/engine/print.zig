/// primarily for printing the pipeline state for debugging purposes
/// most of the code in here is pretty ugly
const std = @import("std");
const pipeline = @import("pipeline.zig");
const api = @import("modules/api.zig");
const gpu = @import("gpu.zig");
const wgpu = @import("wgpu");
const ROI = @import("ROI.zig");
const console = @import("../cli/console.zig");
const DirectedGraph = @import("zig-graph/graph.zig").DirectedGraph;
const Node = @import("Node.zig");
const slog = std.log.scoped(.util);

pub fn printModules(self: *pipeline.Pipeline) void {
    std.debug.print("MODULE LISTING (ORDERED AS APPEARANCE IN POOL ITERATOR)\n", .{});
    var module_pool_handles = self.module_pool.liveHandles();
    while (module_pool_handles.next()) |module_handle| {
        const module = self.module_pool.getPtr(module_handle) catch unreachable;
        // slog.info("Module: {s}, enabled: {any}", .{ module.desc.name, module.enabled });
        const module_text =
            \\ ==== MODULE ======================================
            \\  Input Connector:  <- {any} ({any})
            \\  Input Socket:     "{s}", {any}, {any}, {any}x{any}
            \\  Name:             "{s}"
            \\  Enabled:          {any}
            \\  Output Socket:    "{s}", {any}, {any}, {any}x{any}
            \\  Output Connector: -> {any} ({any})
            \\ ==================================================
            \\
        ;
        const input_texture = if (module.getSocketPtr("input") catch null) |sock| if (sock.private.connector_handle) |h| self.connector_pool.get(h) else null else null;
        const output_texture = if (module.getSocketPtr("output") catch null) |sock| if (sock.private.connector_handle) |h| self.connector_pool.get(h) else null else null;
        std.debug.print(module_text, .{
            if (module.getSocketPtr("input") catch null) |sock| if (sock.private.connector_handle) |h| h.id else null else null,
            if (input_texture) |input_tex| if (input_tex.*) |tex| tex.texture else null else null,
            if (module.getSocketPtr("input") catch null) |sock| sock.name else "null",
            if (module.getSocketPtr("input") catch null) |sock| sock.type else null,
            if (module.getSocketPtr("input") catch null) |sock| sock.format else null,
            // if (module.desc.input_socket) |input_socket| input_socket.roi else null,
            if (module.getSocketPtr("input") catch null) |sock| if (sock.roi) |roi| roi.w else null else null,
            if (module.getSocketPtr("input") catch null) |sock| if (sock.roi) |roi| roi.h else null else null,
            module.desc.name,
            module.enabled,
            if (module.getSocketPtr("output") catch null) |sock| sock.name else "null",
            if (module.getSocketPtr("output") catch null) |sock| sock.type else null,
            if (module.getSocketPtr("output") catch null) |sock| sock.format else null,
            // if (module.desc.output_socket) |output_socket| output_socket.roi else null,
            if (module.getSocketPtr("output") catch null) |sock| if (sock.roi) |roi| roi.w else null else null,
            if (module.getSocketPtr("output") catch null) |sock| if (sock.roi) |roi| roi.h else null else null,
            if (module.getSocketPtr("output") catch null) |sock| if (sock.private.connector_handle) |h| h.id else null else null,
            if (output_texture) |output_tex| if (output_tex.*) |tex| tex.texture else null else null,
        });
    }
}

pub fn printNodes(self: *pipeline.Pipeline) void {
    std.debug.print("NODE LISTING (ORDERED AS APPEARANCE IN POOL ITERATOR)\n", .{});
    var node_pool_handles = self.node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        const node = self.node_pool.getPtr(node_handle) catch unreachable;

        std.debug.print("==== NODE ========================================\n", .{});
        std.debug.print(" ID:                {d}\n", .{node_handle.id});
        std.debug.print(" Entry Point:       \"{s}\" ({s})\n", .{ node.desc.name, @tagName(node.desc.type) });
        for (node.desc.sockets) |sock| {
            if (sock) |s| {
                const connector_text = switch (s.type.direction()) {
                    .input => input: {
                        if (self.getNodeConnectorHandle(s)) |h| {
                            break :input std.fmt.allocPrint(std.heap.page_allocator, "<- {any}", .{h.id}) catch "<- null";
                        } else {
                            break :input "<- null";
                        }
                    },
                    .output => output: {
                        if (self.getNodeConnectorHandle(s)) |h| {
                            break :output std.fmt.allocPrint(std.heap.page_allocator, "-> {any}", .{h.id}) catch "-> null";
                        } else {
                            break :output "-> null";
                        }
                    },
                };
                var tex_text: ?*wgpu.Texture = null;
                if (self.getNodeConnectorHandle(s)) |h| {
                    const conn = self.connector_pool.getPtr(h) catch break;
                    if (conn.*) |c| {
                        tex_text = c.texture;
                    }
                }

                std.debug.print(" Socket:            \"{s}\", {s}, {s}, {any}x{any}\n", .{
                    s.name,
                    @tagName(s.type),
                    @tagName(s.format),
                    if (s.roi) |roi| roi.w else null,
                    if (s.roi) |roi| roi.h else null,
                });
                std.debug.print("  - Connector:      {s} ({any})\n", .{ connector_text, tex_text });
            }
        }
        std.debug.print("==================================================\n", .{});
    }
}

pub fn printNodesGraph(self: *pipeline.Pipeline) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;

    const term_size = console.termsize.termSize(std.fs.File.stdout()) catch unreachable orelse console.termsize.TermSize{
        .width = 80,
        .height = 24,
    };

    try stdout.print("\n", .{});
    // ▒▒▒▒▒▒▒▒▒▒▒▒▒ NODES ▒▒▒▒▒▒▒▒▒▒▒▒▒▒
    for (0..@divFloor(term_size.width, 2) - 4) |_| {
        try stdout.print("▒", .{});
    }
    try stdout.print(" NODES ", .{});
    for (0..@divFloor(term_size.width, 2) - 3) |_| {
        try stdout.print("▒", .{});
    }
    try stdout.print("\n", .{});

    const NodeGraph = DirectedGraph(pipeline.NodeHandle, pipeline.ConnectorHandle, std.hash_map.AutoContext(pipeline.NodeHandle));
    var node_graph = NodeGraph.init(self.allocator);
    defer node_graph.deinit();
    try pipeline.buildGraph(Node, &self.node_pool, &node_graph);

    var iter1 = try node_graph.topSortIterator();
    defer iter1.deinit();

    var printer = node_graph.printer(edgePrinterCb, vertPrinterCb, self, term_size.width);
    try printer.print(stdout, &iter1);

    try stdout.flush(); // Don't forget to flush!
}

pub fn printNodeExecutionOrder(self: *pipeline.Pipeline) void {
    std.debug.print("NODE EXECUTION ORDER\n", .{});
    for (self.node_execution_order.items, 0..) |node_handle, idx| {
        const node = self.node_pool.getPtr(node_handle) catch unreachable;
        std.debug.print(" {d}. {s} (id: {d})\n", .{ idx + 1, node.desc.name, node_handle.id });
    }
}

fn edgePrinterCb(buf: []u8, edge: pipeline.ConnectorHandle, user_data: *anyopaque) []u8 {
    // var self: *pipeline.Pipeline = @ptrCast(@alignCast(user_data));
    // const conn = self.connector_pool.getPtr(edge) catch unreachable;
    // const res = std.fmt.bufPrint(buf, "{s}", .{conn.*.texture.?.name}) catch "<error>";
    _ = user_data;
    const res = std.fmt.bufPrint(buf, "(id: {any})", .{edge.id}) catch "<error>";
    return @constCast(res);
}

fn vertPrinterCb(buf: []u8, vert: pipeline.NodeHandle, user_data: *anyopaque) []u8 {
    var self: *pipeline.Pipeline = @ptrCast(@alignCast(user_data));
    const node = self.node_pool.getPtr(vert) catch unreachable;
    var enabled_srt = "[ ]";
    const node_mod = self.module_pool.getPtr(node.*.mod) catch unreachable;
    if (node_mod.enabled) {
        enabled_srt = "[x]";
    }
    const res = std.fmt.bufPrint(buf, "{s} (id: {any}) {s} > {s}", .{ enabled_srt, vert.id, node_mod.desc.name, node.desc.name }) catch "<error>";
    return @constCast(res);
}
