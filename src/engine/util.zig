const std = @import("std");
const pipeline = @import("pipeline.zig");
const api = @import("api.zig");
const gpu = @import("gpu.zig");
const ROI = @import("ROI.zig");

pub fn printModules(self: *pipeline.Pipeline) void {
    // while (self.module_pool.liveHandles().next()) |module_handle| {
    //     const module = self.module_pool.getColumn(module_handle, .val) catch unreachable;
    for (self.modules.items) |module| {
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
        const input_texture = if (module.desc.input_sock) |sock| if (sock.private.conn_handle) |h| self.connector_pool.getColumn(h, .val) catch unreachable else null else null;
        const output_texture = if (module.desc.output_sock) |sock| if (sock.private.conn_handle) |h| self.connector_pool.getColumn(h, .val) catch unreachable else null else null;
        std.debug.print(module_text, .{
            if (module.desc.input_sock) |sock| if (sock.private.conn_handle) |h| h.id else null else null,
            if (input_texture) |input_tex| input_tex.texture else null,
            if (module.desc.input_sock) |sock| sock.name else "null",
            if (module.desc.input_sock) |sock| sock.type else null,
            if (module.desc.input_sock) |sock| sock.format else null,
            // if (module.desc.input_sock) |input_sock| input_sock.roi else null,
            if (module.desc.input_sock) |sock| sock.roi.?.size.w else null,
            if (module.desc.input_sock) |sock| sock.roi.?.size.h else null,
            module.desc.name,
            module.enabled,
            if (module.desc.output_sock) |sock| sock.name else "null",
            if (module.desc.output_sock) |sock| sock.type else null,
            if (module.desc.output_sock) |sock| sock.format else null,
            // if (module.desc.output_sock) |output_sock| output_sock.roi else null,
            if (module.desc.output_sock) |sock| sock.roi.?.size.w else null,
            if (module.desc.output_sock) |sock| sock.roi.?.size.h else null,
            if (module.desc.output_sock) |sock| if (sock.private.conn_handle) |h| h.id else null else null,
            if (output_texture) |output_tex| output_tex.texture else null,
        });
    }
}

pub fn printNodes(self: *pipeline.Pipeline) void {
    std.debug.print("\n", .{});
    var node_pool_handles = self.node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        const node = self.node_pool.getColumn(node_handle, .val) catch unreachable;

        std.debug.print("==== NODE ========================================\n", .{});
        std.debug.print(" Entry Point:       \"{s}\" ({s})\n", .{ node.desc.entry_point, @tagName(node.desc.type) });
        for (node.desc.sockets) |sock| {
            if (sock) |s| {
                const status_text = switch (s.type.direction()) {
                    .input => std.fmt.allocPrint(std.heap.page_allocator, "<- {any}", .{s.private.connected_to}) catch "<- null",
                    .output => std.fmt.allocPrint(std.heap.page_allocator, "-> {any}", .{s.private.conn_handle.?.id}) catch "-> null",
                };
                const texture = if (s.private.conn_handle) |h| self.connector_pool.getColumn(h, .val) catch unreachable else null;
                const tex_text = if (texture) |tex| tex.texture else null;
                std.debug.print(" Socket:            \"{s}\", {s}, {s}, {any}x{any}\n", .{ s.name, @tagName(s.type), @tagName(s.format), s.roi.?.size.w, s.roi.?.size.h });
                std.debug.print("  - Connector:      {s} ({any})\n", .{ status_text, tex_text });
            }
        }
        std.debug.print("==================================================\n", .{});
    }
}
