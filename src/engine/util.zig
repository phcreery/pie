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
            \\  Input Connector:  {any}
            \\  Input Socket:     "{s}", {any}, {any}, {any}x{any}
            \\  Name:             "{s}"
            \\  Enabled:          {any}
            \\  Output Socket:    "{s}", {any}, {any}, {any}x{any}
            \\  Output Connector: {any}
            \\ ==================================================
            \\
        ;
        const input_texture = if (module.desc.input_sock) |sock| if (sock.private.conn_handle) |handle| self.connector_pool.getColumn(handle, .val) catch unreachable else null else null;
        const output_texture = if (module.desc.output_sock) |sock| if (sock.private.conn_handle) |handle| self.connector_pool.getColumn(handle, .val) catch unreachable else null else null;
        std.debug.print(module_text, .{
            if (input_texture) |input_tex| input_tex.texture else null,
            if (module.desc.input_sock) |input_sock| input_sock.name else "null",
            if (module.desc.input_sock) |input_sock| input_sock.type else null,
            if (module.desc.input_sock) |input_sock| input_sock.format else null,
            // if (module.desc.input_sock) |input_sock| input_sock.roi else null,
            if (module.desc.input_sock) |input_sock| input_sock.roi.?.size.w else null,
            if (module.desc.input_sock) |input_sock| input_sock.roi.?.size.h else null,
            module.desc.name,
            module.enabled,
            if (module.desc.output_sock) |output_sock| output_sock.name else "null",
            if (module.desc.output_sock) |output_sock| output_sock.type else null,
            if (module.desc.output_sock) |output_sock| output_sock.format else null,
            // if (module.desc.output_sock) |output_sock| output_sock.roi else null,
            if (module.desc.output_sock) |output_sock| output_sock.roi.?.size.w else null,
            if (module.desc.output_sock) |output_sock| output_sock.roi.?.size.h else null,
            if (output_texture) |output_tex| output_tex.texture else null,
        });
    }
}

pub fn printNodes(self: *pipeline.Pipeline) void {
    var node_pool_handles = self.node_pool.liveHandles();
    while (node_pool_handles.next()) |node_handle| {
        const node = self.node_pool.getColumn(node_handle, .val) catch unreachable;

        std.debug.print("==== NODE ========================================\n", .{});
        std.debug.print("    Entry Point:   \"{s}\" ({s})\n", .{ node.desc.entry_point, @tagName(node.desc.type) });
        for (node.desc.sockets) |sock| {
            if (sock) |s| {
                std.debug.print("    Socket:  \"{s}\", {s}, {s}, {any}x{any}\n", .{ s.name, @tagName(s.type), @tagName(s.format), s.roi.?.size.w, s.roi.?.size.h });
            }
            // std.debug.print("    Socket:  \"{*}\"\n", .{&sock});
            // std.debug.print("{any}\n", .{sock});
        }
        std.debug.print("==================================================\n", .{});
    }
}
