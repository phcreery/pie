//! The pipeline as a CUI node editor. Modules are nodes, sockets are pins,
//! and `connected_to_module` back-references are the links. Edits go through
//! the pipeline's recording API, so they participate in undo history.

const std = @import("std");
const cui = @import("cui");
const session = @import("session");
const pie = @import("pie");
const util = @import("../cui_util.zig");

const slog = std.log.scoped(.graph);

pub const GraphView = struct {
    allocator: std.mem.Allocator,
    view: cui.cui_node_view = .{},
    strings: util.FrameStrings,

    /// Module ids whose initial position this view has already assigned.
    placed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    depth: std.AutoHashMapUnmanaged(pie.pipeline.ModuleHandle, u32) = .empty,
    visiting: std.AutoHashMapUnmanaged(pie.pipeline.ModuleHandle, void) = .empty,
    slots: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    node_ids: std.AutoHashMapUnmanaged(u64, c_int) = .empty,
    node_owner: std.AutoHashMapUnmanaged(c_int, u64) = .empty,
    pin_ids: std.AutoHashMapUnmanaged(PinKey, c_int) = .empty,
    pin_owner: std.AutoHashMapUnmanaged(c_int, PinKey) = .empty,
    next_node_id: c_int = 1,
    next_pin_id: c_int = 1,

    const PinKey = struct {
        node: u64,
        index: u16,
        /// 0 = input, 1 = output
        kind: u8,
    };

    pub fn init(allocator: std.mem.Allocator) !GraphView {
        return .{ .allocator = allocator, .strings = util.FrameStrings.init(allocator) };
    }

    pub fn deinit(self: *GraphView) void {
        const a = self.allocator;
        self.strings.deinit();
        self.placed.deinit(a);
        self.depth.deinit(a);
        self.visiting.deinit(a);
        self.slots.deinit(a);
        self.node_ids.deinit(a);
        self.node_owner.deinit(a);
        self.pin_ids.deinit(a);
        self.pin_owner.deinit(a);
    }

    pub fn draw(self: *GraphView, s: *session.Session, ui: *cui.cui_ctx) void {
        self.strings.reset();
        self.ensurePositions(s) catch |err| {
            slog.warn("node graph layout failed: {s}", .{@errorName(err)});
        };

        var opts = util.zero(cui.cui_node_editor_opts);
        opts.width = util.fill();
        opts.height = util.fill();
        opts.minimap = true;
        if (!cui.cui_node_editor_begin_ex(ui, "pipeline-graph", &self.view, &opts)) return;
        defer cui.cui_node_editor_end(ui);

        var it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            const mod = s.pipeline.module_pool.getPtr(handle) catch continue;
            self.drawNode(ui, handle, mod);
        }

        it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            const dst = s.pipeline.module_pool.getPtr(handle) catch continue;
            self.drawLinks(s, ui, handle, dst);
        }

        self.processEvents(s, ui);
    }

    fn drawNode(self: *GraphView, ui: *cui.cui_ctx, handle: pie.pipeline.ModuleHandle, mod: *pie.api.Module) void {
        const title = self.strings.fmt("{s}:{s}", .{ mod.name, mod.id }) catch return;

        var opts = util.zero(cui.cui_node_opts);
        opts.width = 180;
        _ = cui.cui_node_begin_ex(ui, self.nodeId(handle), &mod.x, &mod.y, title.ptr, &opts);
        defer cui.cui_node_end(ui);

        var pin_opts = util.zero(cui.cui_pin_opts);
        for (mod.sockets, 0..) |maybe_socket, socket_index| {
            const socket = maybe_socket orelse continue;
            const label = self.strings.fmt("{s}", .{socket.name}) catch continue;
            switch (socket.type.direction()) {
                .input => _ = cui.cui_node_input_ex(ui, self.pinId(handle, @intCast(socket_index), 0), label.ptr, &pin_opts),
                .output => _ = cui.cui_node_output_ex(ui, self.pinId(handle, @intCast(socket_index), 1), label.ptr, &pin_opts),
            }
        }
    }

    fn drawLinks(self: *GraphView, s: *session.Session, ui: *cui.cui_ctx, handle: pie.pipeline.ModuleHandle, mod: *pie.api.Module) void {
        for (mod.sockets, 0..) |maybe_socket, dst_index| {
            const socket = maybe_socket orelse continue;
            const connection = socket.connected_to_module orelse continue;
            _ = s.pipeline.module_pool.getPtr(connection.item) catch continue;
            const out_id = self.pinId(connection.item, @intCast(connection.socket_idx), 1);
            const in_id = self.pinId(handle, @intCast(dst_index), 0);
            _ = cui.cui_node_link(ui, in_id, out_id, in_id);
        }
    }

    fn processEvents(self: *GraphView, s: *session.Session, ui: *cui.cui_ctx) void {
        var removed: c_int = 0;
        while (cui.cui_node_link_removed(ui, &removed)) self.removeLink(s, removed);

        var from: c_int = 0;
        var to: c_int = 0;
        while (cui.cui_node_link_created(ui, &from, &to)) self.createLink(s, from, to);

        var node_id: c_int = 0;
        while (cui.cui_node_deleted(ui, &node_id)) self.deleteNode(s, node_id);
    }

    // ------------------------------------------------------------------
    // ids
    // ------------------------------------------------------------------

    fn nodeId(self: *GraphView, handle: pie.pipeline.ModuleHandle) c_int {
        const gop = self.node_ids.getOrPut(self.allocator, handle.id) catch return 0;
        if (!gop.found_existing) {
            gop.value_ptr.* = self.next_node_id;
            self.node_owner.put(self.allocator, self.next_node_id, handle.id) catch {};
            self.next_node_id += 1;
        }
        return gop.value_ptr.*;
    }

    fn pinId(self: *GraphView, handle: pie.pipeline.ModuleHandle, index: u16, kind: u8) c_int {
        const key = PinKey{ .node = handle.id, .index = index, .kind = kind };
        const gop = self.pin_ids.getOrPut(self.allocator, key) catch return 0;
        if (!gop.found_existing) {
            gop.value_ptr.* = self.next_pin_id;
            self.pin_owner.put(self.allocator, self.next_pin_id, key) catch {};
            self.next_pin_id += 1;
        }
        return gop.value_ptr.*;
    }

    fn pinKey(self: *GraphView, id: c_int) ?PinKey {
        return self.pin_owner.get(id);
    }

    // ------------------------------------------------------------------
    // edits
    // ------------------------------------------------------------------

    fn removeLink(self: *GraphView, s: *session.Session, link_id: c_int) void {
        const key = self.pinKey(link_id) orelse return;
        if (key.kind != 0) return; // links are keyed by their input pin
        disconnectInput(s, key);
    }

    fn createLink(self: *GraphView, s: *session.Session, a: c_int, b: c_int) void {
        const ka = self.pinKey(a) orelse return;
        const kb = self.pinKey(b) orelse return;
        const from = if (ka.kind == 1) ka else kb;
        const to = if (ka.kind == 1) kb else ka;
        if (from.kind != 1 or to.kind != 0 or from.node == to.node) return;
        connect(s, from, to);
    }

    fn connect(s: *session.Session, from: PinKey, to: PinKey) void {
        const src = s.pipeline.module_pool.getPtr(.{ .id = from.node }) catch return;
        const dst = s.pipeline.module_pool.getPtr(.{ .id = to.node }) catch return;
        const src_socket = if (src.sockets[from.index]) |*socket| socket else return;
        const dst_socket = if (dst.sockets[to.index]) |*socket| socket else return;

        if (!pie.api.Socket.areCompatible(src_socket, dst_socket)) {
            slog.warn("rejected link: incompatible sockets", .{});
            return;
        }

        if (dst_socket.connected_to_module != null) {
            s.pipeline.disconnectModule(.{ .id = to.node }, dst_socket.name) catch |err| {
                slog.warn("could not disconnect old link: {s}", .{@errorName(err)});
                return;
            };
        }

        s.pipeline.connectModules(
            .{ .id = from.node },
            src_socket.name,
            .{ .id = to.node },
            dst_socket.name,
        ) catch |err| {
            slog.warn("could not connect modules: {s}", .{@errorName(err)});
            return;
        };
        s.requestRun();
    }

    fn disconnectInput(s: *session.Session, key: PinKey) void {
        const mod = s.pipeline.module_pool.getPtr(.{ .id = key.node }) catch return;
        const socket = if (mod.sockets[key.index]) |*sock| sock else return;
        if (socket.connected_to_module == null) return;
        s.pipeline.disconnectModule(.{ .id = key.node }, socket.name) catch |err| {
            slog.warn("could not disconnect link: {s}", .{@errorName(err)});
            return;
        };
        s.requestRun();
    }

    fn deleteNode(self: *GraphView, s: *session.Session, node_id: c_int) void {
        const handle_id = self.node_owner.get(node_id) orelse return;
        self.removeModuleAndLinks(s, handle_id);
        _ = self.node_owner.remove(node_id);
        _ = self.node_ids.remove(handle_id);
    }

    fn removeModuleAndLinks(self: *GraphView, s: *session.Session, id: u64) void {
        _ = self;
        var it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            const mod = s.pipeline.module_pool.getPtr(handle) catch continue;
            for (mod.sockets) |maybe_socket| {
                const socket = maybe_socket orelse continue;
                const connection = socket.connected_to_module orelse continue;
                if (connection.item.id != id) continue;
                s.pipeline.disconnectModule(handle, socket.name) catch {};
            }
        }

        s.pipeline.removeModule(.{ .id = id }) catch |err| {
            slog.warn("could not remove module: {s}", .{@errorName(err)});
        };
        s.requestRun();
    }

    // ------------------------------------------------------------------
    // initial layout
    // ------------------------------------------------------------------

    fn ensurePositions(self: *GraphView, s: *session.Session) !void {
        var needs_layout = false;
        var probe = s.pipeline.module_pool.liveHandles();
        while (probe.next()) |handle| {
            if (!self.placed.contains(handle.id)) {
                needs_layout = true;
                break;
            }
        }
        if (!needs_layout) return;

        self.depth.clearRetainingCapacity();
        self.visiting.clearRetainingCapacity();
        self.slots.clearRetainingCapacity();

        var it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| _ = try self.moduleDepth(s, handle);

        it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            if (!self.placed.contains(handle.id)) continue;
            const depth = self.depth.get(handle) orelse 0;
            const slot_gop = try self.slots.getOrPut(self.allocator, depth);
            if (!slot_gop.found_existing) slot_gop.value_ptr.* = 0;
            slot_gop.value_ptr.* += 1;
        }

        it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            const mod = s.pipeline.module_pool.getPtr(handle) catch continue;
            if (self.placed.contains(handle.id)) continue;

            const depth = self.depth.get(handle) orelse 0;
            const slot_gop = try self.slots.getOrPut(self.allocator, depth);
            if (!slot_gop.found_existing) slot_gop.value_ptr.* = 0;
            const slot = slot_gop.value_ptr.*;
            slot_gop.value_ptr.* += 1;

            mod.x = 40.0 + @as(f32, @floatFromInt(depth)) * 260.0;
            mod.y = 40.0 + @as(f32, @floatFromInt(slot)) * 160.0;
            try self.placed.put(self.allocator, handle.id, {});
        }
    }

    fn moduleDepth(self: *GraphView, s: *session.Session, handle: pie.pipeline.ModuleHandle) !u32 {
        if (self.depth.get(handle)) |depth| return depth;
        if (self.visiting.contains(handle)) return 0;

        try self.visiting.put(self.allocator, handle, {});
        defer _ = self.visiting.remove(handle);

        var depth: u32 = 0;
        const mod = s.pipeline.module_pool.getPtr(handle) catch return 0;
        for (mod.sockets) |maybe_socket| {
            const socket = maybe_socket orelse continue;
            const connection = socket.connected_to_module orelse continue;
            if (connection.item.id == handle.id) continue;
            const parent_depth = try self.moduleDepth(s, connection.item);
            depth = @max(depth, parent_depth + 1);
        }

        try self.depth.put(self.allocator, handle, depth);
        return depth;
    }
};
