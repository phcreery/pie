const std = @import("std");
const pipeline = @import("pipeline.zig");
const api = @import("modules/api.zig");
const gpu = @import("gpu.zig");
const wgpu = @import("wgpu");
const ROI = @import("ROI.zig");
const console = @import("../cli/console.zig");

pub fn printModules(self: *pipeline.Pipeline) void {
    std.debug.print("MODULE LISTING\n", .{});
    // while (self.module_pool.liveHandles().next()) |module_handle| {
    //     const module = self.module_pool.getColumn(module_handle, .val) catch unreachable;
    for (self.modules.items) |*module| {
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
        // const input_texture = if (module.desc.input_socket) |sock| if (sock.private.connector_handle) |h| self.connector_pool.get(h) catch unreachable else null else null;
        // const output_texture = if (module.desc.output_socket) |sock| if (sock.private.connector_handle) |h| self.connector_pool.get(h) catch unreachable else null else null;
        const input_texture = if (module.getSocketPtr("input")) |sock| if (sock.private.connector_handle) |h| self.connector_pool.get(h) else null else null;
        const output_texture = if (module.getSocketPtr("output")) |sock| if (sock.private.connector_handle) |h| self.connector_pool.get(h) else null else null;
        std.debug.print(module_text, .{
            if (module.getSocketPtr("input")) |sock| if (sock.private.connector_handle) |h| h.id else null else null,
            if (input_texture) |input_tex| if (input_tex.*) |tex| tex.texture else null else null,
            if (module.getSocketPtr("input")) |sock| sock.name else "null",
            if (module.getSocketPtr("input")) |sock| sock.type else null,
            if (module.getSocketPtr("input")) |sock| sock.format else null,
            // if (module.desc.input_socket) |input_socket| input_socket.roi else null,
            if (module.getSocketPtr("input")) |sock| if (sock.roi) |roi| roi.w else null else null,
            if (module.getSocketPtr("input")) |sock| if (sock.roi) |roi| roi.h else null else null,
            module.desc.name,
            module.enabled,
            if (module.getSocketPtr("output")) |sock| sock.name else "null",
            if (module.getSocketPtr("output")) |sock| sock.type else null,
            if (module.getSocketPtr("output")) |sock| sock.format else null,
            // if (module.desc.output_socket) |output_socket| output_socket.roi else null,
            if (module.getSocketPtr("output")) |sock| if (sock.roi) |roi| roi.w else null else null,
            if (module.getSocketPtr("output")) |sock| if (sock.roi) |roi| roi.h else null else null,
            if (module.getSocketPtr("output")) |sock| if (sock.private.connector_handle) |h| h.id else null else null,
            if (output_texture) |output_tex| if (output_tex.*) |tex| tex.texture else null else null,
        });
    }
}

pub fn printNodes(self: *pipeline.Pipeline) void {
    std.debug.print("NODE LISTING (ORDERED AS APPEARANCE IN NODE POOL)\n", .{});
    var node_pool_handles = self.node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        const node = self.node_pool.getPtr(node_handle) catch unreachable;

        std.debug.print("==== NODE ========================================\n", .{});
        std.debug.print(" ID:                {d}\n", .{node_handle.id});
        std.debug.print(" Entry Point:       \"{s}\" ({s})\n", .{ node.desc.name, @tagName(node.desc.type) });
        for (node.desc.sockets) |sock| {
            if (sock) |s| {
                const connector_text = switch (s.type.direction()) {
                    .input => std.fmt.allocPrint(std.heap.page_allocator, "<- {any}", .{self.getNodeConnectorHandle(s).?.id}) catch "<- null",
                    .output => std.fmt.allocPrint(std.heap.page_allocator, "-> {any}", .{self.getNodeConnectorHandle(s).?.id}) catch "-> null",
                };
                var tex_text: ?*wgpu.Texture = null;
                if (self.getNodeConnectorHandle(s)) |h| {
                    const conn = self.connector_pool.getPtr(h) catch unreachable;
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

pub fn printNodes2(self: *pipeline.Pipeline) !void {
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

    var iter1 = try self.node_graph.topSortIterator();
    defer iter1.deinit();

    var printer = self.node_graph.printer(edgePrinterCb, vertPrinterCb, self, term_size.width);
    try printer.print(stdout, &iter1);

    try stdout.flush(); // Don't forget to flush!
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
