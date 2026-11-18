//! The darkroom's node graph: the live pipeline drawn as a node editor.
//!
//! Modules are nodes, their sockets are pins, and the pipeline's
//! `connected_to_module` back-references are the links. Edits go through the
//! pipeline's recording API, so connecting/disconnecting/removing participates
//! in the existing undo history.
//!
//! Node positions live on `Module` (`x`, `y`); the canvas returns the dragged
//! position every frame and this view writes it back. Which modules already
//! received an initial position is view state (`placed`), not engine state.

const std = @import("std");

const ig = @import("cimgui");
const session = @import("session");
const pie = @import("pie");
const nodes = @import("nodes");

const slog = std.log.scoped(.graph);

pub const GraphView = struct {
    allocator: std.mem.Allocator,
    editor: nodes.Editor,

    entries: std.ArrayList(Entry) = .empty,
    needs_fit: bool = false,
    depth: std.AutoHashMapUnmanaged(pie.pipeline.ModuleHandle, u32) = .empty,
    visiting: std.AutoHashMapUnmanaged(pie.pipeline.ModuleHandle, void) = .empty,
    slots: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Module ids whose initial position this view has already assigned.
    placed: std.AutoHashMapUnmanaged(u64, void) = .empty,

    const Entry = struct {
        handle: pie.pipeline.ModuleHandle,
        z: u64,
    };

    pub fn init(allocator: std.mem.Allocator) GraphView {
        return .{ .allocator = allocator, .editor = nodes.Editor.init(allocator) };
    }

    pub fn deinit(self: *GraphView) void {
        self.editor.deinit();
        self.entries.deinit(self.allocator);
        self.depth.deinit(self.allocator);
        self.visiting.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.placed.deinit(self.allocator);
        self.* = undefined;
    }

    /// Ask the next frame to center the graph in the canvas.
    pub fn requestFit(self: *GraphView) void {
        self.needs_fit = true;
    }

    pub fn draw(self: *GraphView, s: *session.Session, rect: session.Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;

        self.ensurePositions(s) catch |err| {
            slog.warn("node graph layout failed: {s}", .{@errorName(err)});
        };

        const flags = ig.ImGuiWindowFlags_NoTitleBar |
            ig.ImGuiWindowFlags_NoResize |
            ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoScrollbar |
            ig.ImGuiWindowFlags_NoScrollWithMouse |
            ig.ImGuiWindowFlags_NoBackground |
            ig.ImGuiWindowFlags_NoSavedSettings |
            ig.ImGuiWindowFlags_NoBringToFrontOnFocus;

        ig.igPushStyleVarImVec2(ig.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
        defer ig.igPopStyleVar();
        ig.igSetNextWindowPos(.{ .x = rect.x, .y = rect.y }, ig.ImGuiCond_Always);
        ig.igSetNextWindowSize(.{ .x = rect.w, .y = rect.h }, ig.ImGuiCond_Always);
        if (!ig.igBegin("##nodegraph", null, flags)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        const canvas_pos = ig.igGetCursorScreenPos();
        const canvas_size = ig.igGetContentRegionAvail();
        self.editor.begin(.{
            .min = .{ .x = canvas_pos.x, .y = canvas_pos.y },
            .max = .{ .x = canvas_pos.x + canvas_size.x, .y = canvas_pos.y + canvas_size.y },
        });

        self.collectEntries(s);
        self.drawNodes(s);
        self.drawLinks(s);

        self.editor.end();

        if (self.needs_fit) {
            self.needs_fit = false;
            self.editor.fit();
        }

        if (self.editor.takeLinkEdit()) |edit| switch (edit) {
            .connect => |request| self.connect(s, request),
            .disconnect => |pin| self.disconnectInput(s, pin),
        };
        if (self.editor.isCanvasHovered() and ig.igIsKeyPressed(ig.ImGuiKey_Delete)) self.deleteSelection(s);
    }

    // ------------------------------------------------------------------
    // submission
    // ------------------------------------------------------------------

    fn collectEntries(self: *GraphView, s: *session.Session) void {
        self.entries.clearRetainingCapacity();
        var it = s.pipeline.module_pool.liveHandles();
        while (it.next()) |handle| {
            self.entries.append(self.allocator, .{
                .handle = handle,
                .z = self.editor.z(handle.id),
            }) catch return;
        }
        // submit back-to-front so overlapping nodes and their widgets stack in z order
        std.sort.insertion(Entry, self.entries.items, {}, lessThanByZ);
    }

    fn drawNodes(self: *GraphView, s: *session.Session) void {
        var inputs: [pie.api.MAX_SOCKETS]nodes.Pin = undefined;
        var outputs: [pie.api.MAX_SOCKETS]nodes.Pin = undefined;

        for (self.entries.items) |entry| {
            const mod = s.pipeline.module_pool.getPtr(entry.handle) catch continue;

            var title_buf: [128]u8 = undefined;
            const title: []const u8 = std.mem.printSentinel(&title_buf, "{s}:{s}", .{ mod.name, mod.id }, 0) catch mod.name;

            var input_count: usize = 0;
            var output_count: usize = 0;
            for (mod.sockets, 0..) |maybe_socket, socket_index| {
                const socket = maybe_socket orelse continue;
                const pin = nodes.Pin{
                    .key = @intCast(socket_index),
                    .label = socket.name,
                };
                switch (socket.type.direction()) {
                    .input => {
                        if (input_count < inputs.len) {
                            inputs[input_count] = pin;
                            input_count += 1;
                        }
                    },
                    .output => {
                        if (output_count < outputs.len) {
                            outputs[output_count] = pin;
                            output_count += 1;
                        }
                    },
                }
            }

            const pos = self.editor.node(.{
                .id = entry.handle.id,
                .pos = .{ .x = mod.x, .y = mod.y },
                .title = title,
                .inputs = inputs[0..input_count],
                .outputs = outputs[0..output_count],
                .disabled = !mod.flags.enabled,
            });

            if (pos.x != mod.x or pos.y != mod.y) {
                mod.x = pos.x;
                mod.y = pos.y;
            }
        }
    }

    fn drawLinks(self: *GraphView, s: *session.Session) void {
        for (self.entries.items) |entry| {
            const dst = s.pipeline.module_pool.getPtr(entry.handle) catch continue;
            for (dst.sockets, 0..) |maybe_socket, dst_index| {
                const socket = maybe_socket orelse continue;
                const connection = socket.connected_to_module orelse continue;
                _ = s.pipeline.module_pool.getPtr(connection.item) catch continue;
                self.editor.link(.{
                    .from = .{
                        .node = connection.item.id,
                        .index = @intCast(connection.socket_idx),
                        .kind = .output,
                    },
                    .to = .{
                        .node = entry.handle.id,
                        .index = @intCast(dst_index),
                        .kind = .input,
                    },
                });
            }
        }
    }

    // ------------------------------------------------------------------
    // edits
    // ------------------------------------------------------------------

    fn connect(self: *GraphView, s: *session.Session, request: nodes.ConnectRequest) void {
        _ = self;
        const src = s.pipeline.module_pool.getPtr(.{ .id = request.from.node }) catch return;
        const dst = s.pipeline.module_pool.getPtr(.{ .id = request.to.node }) catch return;

        const src_socket = if (src.sockets[request.from.index]) |*socket| socket else return;
        const dst_socket = if (dst.sockets[request.to.index]) |*socket| socket else return;

        if (!pie.api.Socket.areCompatible(src_socket, dst_socket)) {
            slog.warn("rejected link: incompatible sockets", .{});
            return;
        }

        // a link dragged off an input leaves that input connected in the model
        if (request.replace) |old| {
            if (!std.meta.eql(old, request.to)) {
                const old_mod = s.pipeline.module_pool.getPtr(.{ .id = old.node }) catch null;
                if (old_mod) |mod| {
                    if (mod.sockets[old.index]) |*old_socket| {
                        if (old_socket.connected_to_module != null) {
                            s.pipeline.disconnectModule(.{ .id = old.node }, old_socket.name) catch |err| {
                                slog.warn("could not disconnect detached link: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
            }
        }

        // an input takes one upstream: replace the existing connection first
        if (dst_socket.connected_to_module != null) {
            s.pipeline.disconnectModule(.{ .id = request.to.node }, dst_socket.name) catch |err| {
                slog.warn("could not disconnect old link: {s}", .{@errorName(err)});
                return;
            };
        }

        s.pipeline.connectModules(
            .{ .id = request.from.node },
            src_socket.name,
            .{ .id = request.to.node },
            dst_socket.name,
        ) catch |err| {
            slog.warn("could not connect modules: {s}", .{@errorName(err)});
            return;
        };

        s.requestRun();
    }

    fn disconnectInput(self: *GraphView, s: *session.Session, pin: nodes.PinRef) void {
        _ = self;
        const mod = s.pipeline.module_pool.getPtr(.{ .id = pin.node }) catch return;
        const socket = if (mod.sockets[pin.index]) |*sock| sock else return;
        if (socket.connected_to_module == null) return;

        s.pipeline.disconnectModule(.{ .id = pin.node }, socket.name) catch |err| {
            slog.warn("could not disconnect link: {s}", .{@errorName(err)});
            return;
        };
        s.requestRun();
    }

    fn deleteSelection(self: *GraphView, s: *session.Session) void {
        // links first, so the history records explicit disconnects
        for (self.editor.selectedLinks()) |ends| {
            const dst = s.pipeline.module_pool.getPtr(.{ .id = ends.to.node }) catch continue;
            const socket = dst.sockets[ends.to.index] orelse continue;
            s.pipeline.disconnectModule(.{ .id = ends.to.node }, socket.name) catch |err| {
                slog.warn("could not disconnect selected link: {s}", .{@errorName(err)});
            };
        }

        // copy the ids: removeModule mutates the pool the editor's selection
        // was derived from
        var ids: [pie.pipeline.MAX_MODULES]u64 = undefined;
        const selected = self.editor.selectedNodes();
        const count = @min(selected.len, ids.len);
        @memcpy(ids[0..count], selected[0..count]);

        for (ids[0..count]) |id| {
            self.removeModuleAndLinks(s, id);
            _ = self.placed.remove(id);
        }
        self.editor.clearSelection();
        s.requestRun();
    }

    fn removeModuleAndLinks(self: *GraphView, s: *session.Session, id: u64) void {
        _ = self;
        // clear every input that still points at the doomed module, otherwise
        // the socket keeps a dangling handle
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
    }

    // ------------------------------------------------------------------
    // initial layout
    // ------------------------------------------------------------------

    /// Lay out modules that have never been placed: rank = longest path from a
    /// source, so the default linear pipelines read left to right.
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

        // reserve the vertical slots already taken by placed nodes
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

            mod.x = 40.0 + @as(f32, @floatFromInt(depth)) * (self.editor.style.node_width + 70.0);
            mod.y = 40.0 + @as(f32, @floatFromInt(slot)) * 150.0;
            try self.placed.put(self.allocator, handle.id, {});
            self.needs_fit = true;
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

fn lessThanByZ(_: void, a: GraphView.Entry, b: GraphView.Entry) bool {
    return a.z < b.z;
}
