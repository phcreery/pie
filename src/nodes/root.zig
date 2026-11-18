//! An immediate-mode node graph canvas for Dear ImGui.
//!
//! Zig port of Nelarius/imnodes (MIT), redesigned around Zig idioms:
//! - no global state: one `Editor` per graph;
//! - the app owns node positions and passes them in every frame; `node`
//!   returns the position after this frame's drag, which the app stores;
//! - nodes are declared with a struct (`NodeDesc`) instead of a
//!   `BeginNode`/`EndNode` pair, so there is no scope state machine;
//! - node and socket ids are `u64`/`u16`, so the engine's generational
//!   handles can be used directly.
//!
//! Features: panning, cursor-anchored zoom, grid, node drag (moving the whole
//! selection), box selection,
//! link dragging with creation events, picking up a connected input's link by
//! its end (rewire or drop on the canvas to remove it), link selection, hover
//! queries, per-editor pan/zoom. Node bodies are drawn from a fixed layout
//! (title + socket rows); embedding arbitrary ImGui widgets inside nodes is
//! not supported yet.
//!
//! The caller draws inside a window; `begin` uses the window's draw list and
//! clips to the supplied canvas rect.

const std = @import("std");
const ig = @import("cimgui");
const geom = @import("geom.zig");

pub const Vec2 = geom.Vec2;
pub const Rect = geom.Rect;
pub const bezierPoint = geom.bezierPoint;

/// RGBA in linear-ish 0..1 space, converted with `ImGui::ColorConvertFloat4ToU32`.
pub const Color = [4]f32;

pub const PinKind = enum { input, output };

/// A socket on a node: the node id plus the socket's index within the module.
pub const PinRef = struct {
    node: u64 = 0,
    index: u16 = 0,
    kind: PinKind = .input,
};

/// A declared socket row.
pub const Pin = struct {
    key: u16 = 0,
    label: []const u8 = "",
};

/// A node submitted for this frame.
pub const NodeDesc = struct {
    id: u64,
    pos: Vec2 = .{},
    title: []const u8 = "",
    inputs: []const Pin = &.{},
    outputs: []const Pin = &.{},
    disabled: bool = false,
};

/// A directed link, output pin -> input pin.
pub const LinkEnds = struct {
    from: PinRef = .{},
    to: PinRef = .{},
};

/// A connection the canvas wants the app to make.
pub const ConnectRequest = struct {
    from: PinRef = .{},
    to: PinRef = .{},
    /// Input pin whose current link was picked up to make this one; the app
    /// should disconnect it when rewiring.
    replace: ?PinRef = null,
};

/// An edit produced by dragging a link.
pub const LinkEdit = union(enum) {
    connect: ConnectRequest,
    /// The link into this input pin was dragged off and dropped.
    disconnect: PinRef,
};

pub const Style = struct {
    background: Color = .{ 0.105, 0.105, 0.105, 1.0 },
    grid_line: Color = .{ 0.16, 0.16, 0.16, 1.0 },
    grid_line_major: Color = .{ 0.22, 0.22, 0.22, 1.0 },

    node_bg: Color = .{ 0.17, 0.17, 0.17, 1.0 },
    node_bg_hovered: Color = .{ 0.20, 0.20, 0.20, 1.0 },
    node_bg_selected: Color = .{ 0.21, 0.24, 0.29, 1.0 },
    node_outline: Color = .{ 0.26, 0.26, 0.26, 1.0 },
    node_outline_selected: Color = .{ 0.36, 0.62, 1.00, 1.0 },

    title_bg: Color = .{ 0.21, 0.21, 0.21, 1.0 },
    title_bg_hovered: Color = .{ 0.24, 0.24, 0.24, 1.0 },
    title_bg_selected: Color = .{ 0.27, 0.33, 0.42, 1.0 },
    title_text: Color = .{ 0.86, 0.86, 0.86, 1.0 },
    text: Color = .{ 0.72, 0.72, 0.72, 1.0 },
    text_disabled: Color = .{ 0.42, 0.42, 0.42, 1.0 },

    pin: Color = .{ 0.55, 0.60, 0.68, 1.0 },
    pin_hovered: Color = .{ 0.98, 0.98, 0.98, 1.0 },

    link: Color = .{ 0.50, 0.55, 0.63, 1.0 },
    link_hovered: Color = .{ 0.86, 0.88, 0.92, 1.0 },
    link_selected: Color = .{ 0.36, 0.62, 1.00, 1.0 },

    selection_fill: Color = .{ 0.26, 0.59, 0.98, 0.16 },
    selection_outline: Color = .{ 0.26, 0.59, 0.98, 0.85 },

    node_width: f32 = 196,
    node_padding: f32 = 8,
    row_gap: f32 = 5,
    corner_rounding: f32 = 4,
    pin_radius: f32 = 4.5,
    pin_hover_radius: f32 = 11,
    link_thickness: f32 = 2,
    link_hover_distance: f32 = 7,
    grid_step: f32 = 32,
    grid_major_every: u32 = 4,
    /// Hides minor grid lines once they get closer together than this, in
    /// screen pixels.
    grid_min_spacing: f32 = 6,

    zoom_min: f32 = 0.2,
    zoom_max: f32 = 4.0,
    /// Exponential zoom per wheel unit (a notch is ~1.0).
    zoom_speed: f32 = 0.15,
};

const NodeState = struct {
    z: u64 = 0,
    rect: Rect = .{},
    last_seen: u64 = 0,
    selected: bool = false,
    hovered: bool = false,
};

const LinkKey = struct {
    out: PinRef = .{},
    in: PinRef = .{},
};

const LinkState = struct {
    last_seen: u64 = 0,
    selected: bool = false,
};

const FrameLink = struct {
    key: LinkKey,
    from: Vec2,
    to: Vec2,
};

const Interaction = union(enum) {
    none,
    panning,
    drag_node: u64,
    drag_link: PinRef,
    /// Dragging an existing link by its input end; `from` stays attached.
    drag_link_detached: struct {
        from: PinRef,
        origin: PinRef,
    },
    box_select: struct {
        start: Vec2,
        additive: bool,
    },
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    style: Style = .{},
    pan: Vec2 = .{},
    /// Screen pixels per graph unit. Node positions, sizes and pins are graph
    /// units; everything drawn and hit-tested is converted through `zoom`.
    zoom: f32 = 1,
    /// Screen pixels per ImGui wheel unit. Trackpads report both axes.
    pan_speed: f32 = 16,

    nodes: std.AutoHashMapUnmanaged(u64, NodeState) = .empty,
    links: std.AutoHashMapUnmanaged(LinkKey, LinkState) = .empty,
    pins: std.AutoHashMapUnmanaged(PinRef, Vec2) = .empty,
    frame_links: std.ArrayList(FrameLink) = .empty,
    prev_links: std.ArrayList(FrameLink) = .empty,
    sel_nodes: std.ArrayList(u64) = .empty,
    sel_links: std.ArrayList(LinkEnds) = .empty,
    stale_nodes: std.ArrayList(u64) = .empty,
    stale_links: std.ArrayList(LinkKey) = .empty,

    frame: u64 = 0,
    next_z: u64 = 1,
    canvas: Rect = .{},
    mouse: Vec2 = .{},
    window_hovered: bool = false,

    interaction: Interaction = .none,
    hovered_pin: ?PinRef = null,
    hovered_node: ?u64 = null,
    hovered_link: ?LinkKey = null,
    pending_edit: ?LinkEdit = null,
    /// Hide this link for one frame after a detach edit is emitted.
    suppress_link: ?LinkKey = null,

    last_pin: ?PinRef = null,
    last_node: ?u64 = null,
    last_link: ?LinkKey = null,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        const a = self.allocator;
        self.nodes.deinit(a);
        self.links.deinit(a);
        self.pins.deinit(a);
        self.frame_links.deinit(a);
        self.prev_links.deinit(a);
        self.sel_nodes.deinit(a);
        self.sel_links.deinit(a);
        self.stale_nodes.deinit(a);
        self.stale_links.deinit(a);
        self.* = undefined;
    }

    // ------------------------------------------------------------------
    // frame
    // ------------------------------------------------------------------

    pub fn begin(self: *Editor, canvas: Rect) void {
        self.frame += 1;
        self.canvas = canvas;
        self.prune();

        self.pins.clearRetainingCapacity();
        self.frame_links.clearRetainingCapacity();

        const io = ig.igGetIO();
        self.mouse = fromIm(io.*.MousePos);

        switch (self.interaction) {
            .panning => self.pan = self.pan.add(fromIm(io.*.MouseDelta)),
            else => {},
        }

        self.window_hovered = ig.igIsWindowHovered(ig.ImGuiHoveredFlags_None);

        // two-finger scroll pans both axes, shift+wheel turns a mouse's
        // vertical wheel into horizontal panning, and ctrl/cmd+wheel zooms
        // around the cursor
        if (self.window_hovered) {
            const wheel_x = io.*.MouseWheelH;
            const wheel_y = io.*.MouseWheel;
            if ((io.*.KeyCtrl or io.*.KeySuper) and (wheel_x != 0 or wheel_y != 0)) {
                self.zoomAt(self.mouse, wheel_y + wheel_x);
            } else if (wheel_x != 0) {
                self.pan.x += wheel_x * self.pan_speed;
                self.pan.y += wheel_y * self.pan_speed;
            } else if (wheel_y != 0) {
                if (io.*.KeyShift) {
                    self.pan.x += wheel_y * self.pan_speed;
                } else {
                    self.pan.y += wheel_y * self.pan_speed;
                }
            }
        }

        const dl = ig.igGetWindowDrawList();
        ig.ImDrawList_PushClipRect(dl, toIm(canvas.min), toIm(canvas.max), true);

        ig.ImDrawList_AddRectFilled(dl, toIm(canvas.min), toIm(canvas.max), col(self.style.background));
        self.drawGrid(dl);
        self.drawLinks(dl);
        self.suppress_link = null;
    }

    pub fn end(self: *Editor) void {
        const io = ig.igGetIO();
        const mouse = self.mouse;
        const can_hover = self.window_hovered and self.canvas.contains(mouse);

        self.hovered_pin = if (can_hover) self.resolvePin(mouse) else null;
        self.hovered_node = if (can_hover and self.hovered_pin == null) self.resolveNode(mouse) else null;
        self.hovered_link = if (can_hover and self.hovered_pin == null and self.hovered_node == null)
            self.resolveLink(mouse)
        else
            null;

        const left_clicked = ig.igIsMouseClickedEx(ig.ImGuiMouseButton_Left, false);
        const left_released = ig.igIsMouseReleased(ig.ImGuiMouseButton_Left);
        const middle_clicked = ig.igIsMouseClickedEx(ig.ImGuiMouseButton_Middle, false);
        const middle_released = ig.igIsMouseReleased(ig.ImGuiMouseButton_Middle);
        const additive = io.*.KeyCtrl or io.*.KeySuper;
        const alt = io.*.KeyAlt;

        // start an interaction
        if (std.meta.activeTag(self.interaction) == .none and can_hover) {
            if ((middle_clicked) or (left_clicked and alt)) {
                self.interaction = .panning;
            } else if (left_clicked) {
                if (self.hovered_pin) |pin| {
                    if (pin.kind == .input) {
                        if (self.findLinkInto(pin)) |key| {
                            // grab the link's input end instead of starting a new one
                            self.interaction = .{ .drag_link_detached = .{ .from = key.out, .origin = pin } };
                        } else {
                            self.interaction = .{ .drag_link = pin };
                        }
                    } else {
                        self.interaction = .{ .drag_link = pin };
                    }
                } else if (self.hovered_link) |key| {
                    self.selectLink(key, additive);
                } else if (self.hovered_node) |id| {
                    self.selectNode(id, additive);
                    self.bumpZ(id);
                    self.interaction = .{ .drag_node = id };
                } else {
                    if (!additive) self.clearSelection();
                    self.interaction = .{ .box_select = .{ .start = mouse, .additive = additive } };
                }
            }
        }

        // finish an interaction
        switch (self.interaction) {
            .none => {},
            .panning => {
                // panning can be started with the middle button or alt+left
                if (middle_released or left_released) self.interaction = .none;
            },
            .drag_node => {
                if (left_released) self.interaction = .none;
            },
            .drag_link => |from| {
                if (left_released) {
                    if (self.hovered_pin) |to| {
                        if (to.kind != from.kind and to.node != from.node) {
                            self.pending_edit = if (from.kind == .output)
                                .{ .connect = .{ .from = from, .to = to } }
                            else
                                .{ .connect = .{ .from = to, .to = from } };
                        }
                    }
                    self.interaction = .none;
                }
            },
            .drag_link_detached => |drag| {
                if (left_released) {
                    const key = LinkKey{ .out = drag.from, .in = drag.origin };
                    if (self.hovered_pin) |to| {
                        if (to.kind == .input and to.node != drag.from.node and !std.meta.eql(to, drag.origin)) {
                            self.pending_edit = .{ .connect = .{
                                .from = drag.from,
                                .to = to,
                                .replace = drag.origin,
                            } };
                            self.suppress_link = key;
                        }
                        // dropped on the same input or an invalid pin: restore it
                    } else if (self.canvas.contains(mouse)) {
                        // dropped on empty canvas: remove the link
                        self.pending_edit = .{ .disconnect = drag.origin };
                        self.suppress_link = key;
                    }
                    self.interaction = .none;
                }
            },
            .box_select => |box| {
                if (left_released) {
                    self.applyBoxSelection(box.start, box.additive);
                    self.interaction = .none;
                }
            },
        }

        const dl = ig.igGetWindowDrawList();
        self.drawInteraction(dl);

        self.rebuildSelection();
        self.last_pin = self.hovered_pin;
        self.last_node = self.hovered_node;
        self.last_link = self.hovered_link;

        std.mem.swap(std.ArrayList(FrameLink), &self.prev_links, &self.frame_links);
        self.frame_links.clearRetainingCapacity();

        ig.ImDrawList_PopClipRect(dl);
    }

    // ------------------------------------------------------------------
    // submission
    // ------------------------------------------------------------------

    /// Submit one node. Returns the position after this frame's drag; the
    /// caller should store it back into its model.
    pub fn node(self: *Editor, desc: NodeDesc) Vec2 {
        const a = self.allocator;
        var pos = desc.pos;

        switch (self.interaction) {
            .drag_node => |dragged| {
                // dragging moves the whole selection; the grabbed node follows
                // the mouse even when an additive click just deselected it
                const selected = if (self.nodes.get(desc.id)) |state| state.selected else false;
                if (desc.id == dragged or selected) {
                    const io = ig.igGetIO();
                    pos = pos.add(fromIm(io.*.MouseDelta).scale(1.0 / self.zoom));
                }
            },
            else => {},
        }

        const gop = self.nodes.getOrPut(a, desc.id) catch return pos;
        const state = gop.value_ptr;
        if (!gop.found_existing) {
            state.* = .{ .z = self.next_z };
            self.next_z += 1;
        }
        state.last_seen = self.frame;
        state.hovered = self.last_node != null and self.last_node.? == desc.id;

        const font = ig.igGetFontSize();
        const size = self.nodeSize(desc, font);
        state.rect = Rect.fromPosSize(pos, size);
        self.registerPins(desc, pos, size, font);

        const screen = Rect.fromPosSize(self.toScreen(pos), size.scale(self.zoom));
        if (!screen.overlaps(self.canvas)) return pos;

        const dl = ig.igGetWindowDrawList();
        const pad = self.style.node_padding * self.zoom;
        const title_h = (font + self.style.node_padding) * self.zoom;
        const rounding = self.style.corner_rounding * self.zoom;

        const bg = if (state.selected)
            self.style.node_bg_selected
        else if (state.hovered)
            self.style.node_bg_hovered
        else
            self.style.node_bg;
        const title_bg = if (state.selected)
            self.style.title_bg_selected
        else if (state.hovered)
            self.style.title_bg_hovered
        else
            self.style.title_bg;
        const outline = if (state.selected) self.style.node_outline_selected else self.style.node_outline;

        ig.ImDrawList_AddRectFilledEx(dl, toIm(screen.min), toIm(screen.max), col(bg), rounding, ig.ImDrawFlags_RoundCornersAll);
        ig.ImDrawList_AddRectFilledEx(
            dl,
            toIm(screen.min),
            toIm(.{ .x = screen.max.x, .y = screen.min.y + title_h }),
            col(title_bg),
            rounding,
            ig.ImDrawFlags_RoundCornersTop,
        );
        ig.ImDrawList_AddRectEx(dl, toIm(screen.min), toIm(screen.max), col(outline), rounding, 1.0, ig.ImDrawFlags_RoundCornersAll);

        // labels are clipped to the node so long names cannot spill over
        ig.ImDrawList_PushClipRect(dl, toIm(screen.min), toIm(screen.max), true);

        // draw the body text at the zoomed size; positions and text metrics
        // must come from the same scaled font
        const font_base = ig.igGetStyle().*.FontSizeBase;
        const scale_font = self.zoom != 1.0;
        if (scale_font) ig.igPushFontFloat(null, font_base * self.zoom);
        defer if (scale_font) ig.igPopFont();

        var buf: [128]u8 = undefined;
        const title = zstr(&buf, desc.title);
        const title_size = ig.igCalcTextSize(title.ptr);
        ig.ImDrawList_AddText(
            dl,
            toIm(.{ .x = screen.min.x + pad, .y = screen.min.y + (title_h - title_size.y) * 0.5 }),
            col(if (desc.disabled) self.style.text_disabled else self.style.title_text),
            title.ptr,
        );

        const row_h = (font + self.style.row_gap) * self.zoom;
        const body_top = screen.min.y + title_h + pad;
        const label_inset = (self.style.node_padding + self.style.pin_radius * 2.0) * self.zoom;

        for (desc.inputs, 0..) |pin, i| {
            const center_y = body_top + row_h * (@as(f32, @floatFromInt(i)) + 0.5);
            const label = zstr(&buf, pin.label);
            const label_size = ig.igCalcTextSize(label.ptr);
            ig.ImDrawList_AddText(
                dl,
                toIm(.{ .x = screen.min.x + label_inset, .y = center_y - label_size.y * 0.5 }),
                col(if (desc.disabled) self.style.text_disabled else self.style.text),
                label.ptr,
            );
        }
        for (desc.outputs, 0..) |pin, i| {
            const center_y = body_top + row_h * (@as(f32, @floatFromInt(i)) + 0.5);
            const label = zstr(&buf, pin.label);
            const label_size = ig.igCalcTextSize(label.ptr);
            ig.ImDrawList_AddText(
                dl,
                toIm(.{ .x = screen.max.x - label_inset - label_size.x, .y = center_y - label_size.y * 0.5 }),
                col(if (desc.disabled) self.style.text_disabled else self.style.text),
                label.ptr,
            );
        }
        ig.ImDrawList_PopClipRect(dl);

        // pins sit on the node edge; drawn after the label clip so they are
        // not cut in half
        for (desc.inputs) |pin| self.drawPin(dl, .{ .node = desc.id, .index = pin.key, .kind = .input });
        for (desc.outputs) |pin| self.drawPin(dl, .{ .node = desc.id, .index = pin.key, .kind = .output });

        return pos;
    }

    /// Submit a link. Links are drawn from the previous frame's geometry so
    /// they render underneath the nodes; `end` caches this frame's geometry
    /// for the next frame.
    pub fn link(self: *Editor, ends: LinkEnds) void {
        var out_pin = ends.from;
        var in_pin = ends.to;
        if (out_pin.kind == .input and in_pin.kind == .output) {
            const tmp = out_pin;
            out_pin = in_pin;
            in_pin = tmp;
        }
        if (out_pin.kind != .output or in_pin.kind != .input) return;
        if (out_pin.node == in_pin.node) return;

        const key = LinkKey{ .out = out_pin, .in = in_pin };
        const gop = self.links.getOrPut(self.allocator, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.last_seen = self.frame;

        const from = self.pins.get(out_pin) orelse return;
        const to = self.pins.get(in_pin) orelse return;
        self.frame_links.append(self.allocator, .{ .key = key, .from = from, .to = to }) catch {};
    }

    // ------------------------------------------------------------------
    // queries
    // ------------------------------------------------------------------

    pub fn takeLinkEdit(self: *Editor) ?LinkEdit {
        defer self.pending_edit = null;
        return self.pending_edit;
    }

    pub fn hoveredNodeId(self: *const Editor) ?u64 {
        return self.hovered_node;
    }

    pub fn hoveredPinRef(self: *const Editor) ?PinRef {
        return self.hovered_pin;
    }

    pub fn hoveredLinkEnds(self: *const Editor) ?LinkEnds {
        const key = self.hovered_link orelse return null;
        return .{ .from = key.out, .to = key.in };
    }

    pub fn selectedNodes(self: *const Editor) []const u64 {
        return self.sel_nodes.items;
    }

    pub fn selectedLinks(self: *const Editor) []const LinkEnds {
        return self.sel_links.items;
    }

    pub fn isCanvasHovered(self: *const Editor) bool {
        return self.window_hovered and self.canvas.contains(self.mouse);
    }

    pub fn z(self: *const Editor, id: u64) u64 {
        const state = self.nodes.get(id) orelse return 0;
        return state.z;
    }

    pub fn panValue(self: *const Editor) Vec2 {
        return self.pan;
    }

    pub fn setPan(self: *Editor, pan: Vec2) void {
        self.pan = pan;
    }

    pub fn zoomValue(self: *const Editor) f32 {
        return self.zoom;
    }

    /// Change zoom by `delta` wheel units, keeping the graph point under
    /// `anchor` (screen coordinates) fixed.
    pub fn zoomAt(self: *Editor, anchor: Vec2, delta: f32) void {
        self.setZoomAnchored(self.zoom * @exp(delta * self.style.zoom_speed), anchor);
    }

    /// Set the zoom, keeping the canvas center fixed.
    pub fn setZoom(self: *Editor, zoom: f32) void {
        const center = self.canvas.min.add(self.canvas.size().scale(0.5));
        self.setZoomAnchored(zoom, center);
    }

    fn setZoomAnchored(self: *Editor, zoom: f32, anchor: Vec2) void {
        const next = std.math.clamp(zoom, self.style.zoom_min, self.style.zoom_max);
        if (next == self.zoom) return;
        const world = self.toWorld(anchor);
        self.zoom = next;
        self.pan = anchor.sub(self.canvas.min).sub(world.scale(next));
    }

    /// Center the laid-out nodes in the canvas, zooming out when they do not
    /// fit. Never zooms past 1:1.
    pub fn fit(self: *Editor) void {
        var bounds: ?Rect = null;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_seen != self.frame) continue;
            const rect = entry.value_ptr.rect;
            if (bounds) |*b| {
                b.min = .{ .x = @min(b.min.x, rect.min.x), .y = @min(b.min.y, rect.min.y) };
                b.max = .{ .x = @max(b.max.x, rect.max.x), .y = @max(b.max.y, rect.max.y) };
            } else {
                bounds = rect;
            }
        }

        const b = bounds orelse return;
        const content = b.size();
        if (content.x <= 0 or content.y <= 0) return;
        const canvas = self.canvas.size();
        const margin: f32 = 24;

        const zx = (canvas.x - margin * 2) / content.x;
        const zy = (canvas.y - margin * 2) / content.y;
        self.zoom = std.math.clamp(@min(zx, zy), self.style.zoom_min, 1.0);

        self.pan = .{
            .x = (canvas.x - content.x * self.zoom) * 0.5 - b.min.x * self.zoom,
            .y = (canvas.y - content.y * self.zoom) * 0.5 - b.min.y * self.zoom,
        };
    }

    pub fn clearSelection(self: *Editor) void {
        var node_it = self.nodes.valueIterator();
        while (node_it.next()) |state| state.selected = false;
        var link_it = self.links.valueIterator();
        while (link_it.next()) |state| state.selected = false;
        self.sel_nodes.clearRetainingCapacity();
        self.sel_links.clearRetainingCapacity();
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    /// Screen position of the graph origin.
    fn origin(self: *const Editor) Vec2 {
        return self.canvas.min.add(self.pan);
    }

    fn toScreen(self: *const Editor, p: Vec2) Vec2 {
        return self.origin().add(p.scale(self.zoom));
    }

    fn toWorld(self: *const Editor, p: Vec2) Vec2 {
        return p.sub(self.origin()).scale(1.0 / self.zoom);
    }

    fn prune(self: *Editor) void {
        const a = self.allocator;
        self.stale_nodes.clearRetainingCapacity();
        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            if (entry.value_ptr.last_seen + 2 <= self.frame) self.stale_nodes.append(a, entry.key_ptr.*) catch {};
        }
        for (self.stale_nodes.items) |id| _ = self.nodes.remove(id);

        self.stale_links.clearRetainingCapacity();
        var link_it = self.links.iterator();
        while (link_it.next()) |entry| {
            if (entry.value_ptr.last_seen + 2 <= self.frame) self.stale_links.append(a, entry.key_ptr.*) catch {};
        }
        for (self.stale_links.items) |key| _ = self.links.remove(key);
    }

    fn nodeSize(self: *const Editor, desc: NodeDesc, font: f32) Vec2 {
        const rows = @max(desc.inputs.len, desc.outputs.len);
        const title_h = font + self.style.node_padding;
        const row_h = font + self.style.row_gap;
        const height = title_h + self.style.node_padding +
            @as(f32, @floatFromInt(rows)) * row_h + self.style.node_padding;
        return .{ .x = self.style.node_width, .y = height };
    }

    fn registerPins(self: *Editor, desc: NodeDesc, pos: Vec2, size: Vec2, font: f32) void {
        const pad = self.style.node_padding;
        const title_h = font + pad;
        const row_h = font + self.style.row_gap;
        const body_top = pos.y + title_h + pad;
        for (desc.inputs, 0..) |pin, i| {
            const y = body_top + row_h * (@as(f32, @floatFromInt(i)) + 0.5);
            self.pins.put(self.allocator, .{ .node = desc.id, .index = pin.key, .kind = .input }, .{ .x = pos.x, .y = y }) catch {};
        }
        for (desc.outputs, 0..) |pin, i| {
            const y = body_top + row_h * (@as(f32, @floatFromInt(i)) + 0.5);
            self.pins.put(self.allocator, .{ .node = desc.id, .index = pin.key, .kind = .output }, .{ .x = pos.x + size.x, .y = y }) catch {};
        }
    }

    fn drawPin(self: *Editor, dl: anytype, ref: PinRef) void {
        const grid_pos = self.pins.get(ref) orelse return;
        const screen = self.toScreen(grid_pos);
        const hovered = self.last_pin != null and std.meta.eql(self.last_pin.?, ref);
        const c = if (hovered) self.style.pin_hovered else self.style.pin;
        ig.ImDrawList_AddCircleFilled(dl, toIm(screen), self.style.pin_radius * self.zoom, col(c), 0);
    }

    fn drawGrid(self: *Editor, dl: anytype) void {
        if (self.style.grid_step <= 1) return;
        const step = self.style.grid_step * self.zoom;
        if (step < self.style.grid_min_spacing) {
            // too dense to read: keep only the major lines
            self.drawGridAxis(dl, true);
            self.drawGridAxis(dl, false);
            return;
        }
        self.drawGridAxis(dl, true);
        self.drawGridAxis(dl, false);
    }

    fn drawGridAxis(self: *Editor, dl: anytype, vertical: bool) void {
        const every: i64 = @max(self.style.grid_major_every, 1);
        const step = self.style.grid_step * self.zoom;
        const major_only = step < self.style.grid_min_spacing;
        const axis_step = if (major_only) step * @as(f32, @floatFromInt(every)) else step;
        if (axis_step <= 0.5) return;

        const graph_origin = self.origin();
        const lo = if (vertical) self.canvas.min.x else self.canvas.min.y;
        const hi = if (vertical) self.canvas.max.x else self.canvas.max.y;
        const base = if (vertical) graph_origin.x else graph_origin.y;

        // line indices are anchored to the graph origin so majors stay put
        // while panning
        const start: i64 = @intFromFloat(@floor((lo - base) / axis_step));
        var index = start;
        var p = base + @as(f32, @floatFromInt(index)) * axis_step;
        while (p <= hi) : ({
            index += 1;
            p += axis_step;
        }) {
            const major = major_only or @mod(index, every) == 0;
            const c = if (major) self.style.grid_line_major else self.style.grid_line;
            if (vertical) {
                ig.ImDrawList_AddLine(dl, toIm(.{ .x = p, .y = self.canvas.min.y }), toIm(.{ .x = p, .y = self.canvas.max.y }), col(c));
            } else {
                ig.ImDrawList_AddLine(dl, toIm(.{ .x = self.canvas.min.x, .y = p }), toIm(.{ .x = self.canvas.max.x, .y = p }), col(c));
            }
        }
    }

    fn drawLinks(self: *Editor, dl: anytype) void {
        const hidden = self.hiddenLink();
        const thickness = @max(self.style.link_thickness * self.zoom, 1.0);
        for (self.prev_links.items) |frame_link| {
            if (hidden) |h| {
                if (std.meta.eql(h, frame_link.key)) continue;
            }
            const from = self.toScreen(frame_link.from);
            const to = self.toScreen(frame_link.to);
            const ctrl = geom.linkControls(from, to);
            const selected = if (self.links.get(frame_link.key)) |state| state.selected else false;
            const hovered = self.last_link != null and std.meta.eql(self.last_link.?, frame_link.key);
            const c = if (selected)
                self.style.link_selected
            else if (hovered)
                self.style.link_hovered
            else
                self.style.link;
            ig.ImDrawList_AddBezierCubic(
                dl,
                toIm(from),
                toIm(ctrl[0]),
                toIm(ctrl[1]),
                toIm(to),
                col(c),
                thickness,
                0,
            );
        }
    }

    fn drawInteraction(self: *Editor, dl: anytype) void {
        switch (self.interaction) {
            .box_select => |box| {
                const rect = Rect.normalized(box.start, self.mouse);
                ig.ImDrawList_AddRectFilled(dl, toIm(rect.min), toIm(rect.max), col(self.style.selection_fill));
                ig.ImDrawList_AddRectEx(dl, toIm(rect.min), toIm(rect.max), col(self.style.selection_outline), 0, 1.0, ig.ImDrawFlags_RoundCornersAll);
            },
            .drag_link => |from| self.drawLinkPreview(dl, from),
            .drag_link_detached => |drag| self.drawLinkPreview(dl, drag.from),
            else => {},
        }
    }

    fn drawLinkPreview(self: *Editor, dl: anytype, from: PinRef) void {
        const grid_pos = self.pins.get(from) orelse return;
        const start = self.toScreen(grid_pos);
        const ctrl = geom.linkControls(start, self.mouse);
        ig.ImDrawList_AddBezierCubic(
            dl,
            toIm(start),
            toIm(ctrl[0]),
            toIm(ctrl[1]),
            toIm(self.mouse),
            col(self.style.link_hovered),
            @max(self.style.link_thickness * self.zoom, 1.0),
            0,
        );
        if (self.hovered_pin) |pin| {
            if (pin.kind != from.kind) {
                if (self.pins.get(pin)) |target| {
                    ig.ImDrawList_AddCircleFilled(
                        dl,
                        toIm(self.toScreen(target)),
                        self.style.pin_hover_radius * self.zoom,
                        col(self.style.pin_hovered),
                        0,
                    );
                }
            }
        }
    }

    fn hiddenLink(self: *const Editor) ?LinkKey {
        switch (self.interaction) {
            .drag_link_detached => |drag| return .{ .out = drag.from, .in = drag.origin },
            else => return self.suppress_link,
        }
    }

    fn findLinkInto(self: *const Editor, pin: PinRef) ?LinkKey {
        for (self.frame_links.items) |frame_link| {
            if (std.meta.eql(frame_link.key.in, pin)) return frame_link.key;
        }
        return null;
    }

    fn resolvePin(self: *Editor, mouse: Vec2) ?PinRef {
        const mouse_grid = self.toWorld(mouse);
        // hover radii are screen-space, so convert to graph units
        const radius = self.style.pin_hover_radius / self.zoom;
        const max_d2 = radius * radius;
        var best: ?PinRef = null;
        var best_d2 = std.math.floatMax(f32);
        var it = self.pins.iterator();
        while (it.next()) |entry| {
            const d2 = entry.value_ptr.distanceSquared(mouse_grid);
            if (d2 <= max_d2 and d2 < best_d2) {
                best_d2 = d2;
                best = entry.key_ptr.*;
            }
        }
        return best;
    }

    fn resolveNode(self: *Editor, mouse: Vec2) ?u64 {
        const mouse_grid = self.toWorld(mouse);
        var best: ?u64 = null;
        var best_z: u64 = 0;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.last_seen != self.frame) continue;
            if (!state.rect.contains(mouse_grid)) continue;
            if (best == null or state.z >= best_z) {
                best = entry.key_ptr.*;
                best_z = state.z;
            }
        }
        return best;
    }

    fn resolveLink(self: *Editor, mouse: Vec2) ?LinkKey {
        var best: ?LinkKey = null;
        var best_d = std.math.floatMax(f32);
        for (self.frame_links.items) |frame_link| {
            // hit-test the curve as drawn: screen space, so the threshold is
            // a constant number of pixels at any zoom
            const from = self.toScreen(frame_link.from);
            const to = self.toScreen(frame_link.to);
            const ctrl = geom.linkControls(from, to);
            const d = geom.bezierDistance(from, ctrl[0], ctrl[1], to, mouse);
            if (d <= self.style.link_hover_distance and d < best_d) {
                best_d = d;
                best = frame_link.key;
            }
        }
        return best;
    }

    fn applyBoxSelection(self: *Editor, start: Vec2, additive: bool) void {
        const box = Rect.normalized(self.toWorld(start), self.toWorld(self.mouse));
        if (!additive) self.clearSelection();
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_seen != self.frame) continue;
            if (entry.value_ptr.rect.overlaps(box)) entry.value_ptr.selected = true;
        }
    }

    fn selectNode(self: *Editor, id: u64, additive: bool) void {
        const state = self.nodes.getPtr(id) orelse return;
        if (additive) {
            state.selected = !state.selected;
            return;
        }
        if (!state.selected) {
            self.clearSelection();
            state.selected = true;
        }
    }

    fn selectLink(self: *Editor, key: LinkKey, additive: bool) void {
        const state = self.links.getPtr(key) orelse return;
        if (additive) {
            state.selected = !state.selected;
            return;
        }
        if (!state.selected) {
            self.clearSelection();
            state.selected = true;
        }
    }

    fn bumpZ(self: *Editor, id: u64) void {
        const state = self.nodes.getPtr(id) orelse return;
        state.z = self.next_z;
        self.next_z += 1;
    }

    fn rebuildSelection(self: *Editor) void {
        const a = self.allocator;
        self.sel_nodes.clearRetainingCapacity();
        self.sel_links.clearRetainingCapacity();
        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            if (entry.value_ptr.selected) self.sel_nodes.append(a, entry.key_ptr.*) catch {};
        }
        var link_it = self.links.iterator();
        while (link_it.next()) |entry| {
            if (!entry.value_ptr.selected) continue;
            self.sel_links.append(a, .{ .from = entry.key_ptr.out, .to = entry.key_ptr.in }) catch {};
        }
    }
};

fn toIm(p: Vec2) ig.ImVec2 {
    return .{ .x = p.x, .y = p.y };
}

fn fromIm(p: ig.ImVec2) Vec2 {
    return .{ .x = p.x, .y = p.y };
}

fn col(c: Color) ig.ImU32 {
    return ig.igColorConvertFloat4ToU32(.{ .x = c[0], .y = c[1], .z = c[2], .w = c[3] });
}

fn zstr(buf: []u8, text: []const u8) [:0]const u8 {
    return std.mem.printSentinel(buf, "{s}", .{text}, 0) catch "";
}

test {
    _ = geom;
}

test "headless: hover, node drag and link creation" {
    const ctx = ig.igCreateContext(null);
    defer ig.igDestroyContext(ctx);
    ig.igSetCurrentContext(ctx);

    const io = ig.igGetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    _ = ig.ImFontAtlas_Build(io.*.Fonts);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    const node_a = NodeDesc{
        .id = 1,
        .pos = .{ .x = 40, .y = 40 },
        .title = "a",
        .inputs = &.{.{ .key = 0, .label = "in" }},
        .outputs = &.{.{ .key = 0, .label = "out" }},
    };
    const node_b = NodeDesc{
        .id = 2,
        .pos = .{ .x = 300, .y = 40 },
        .title = "b",
        .inputs = &.{.{ .key = 0, .label = "in" }},
        .outputs = &.{.{ .key = 0, .label = "out" }},
    };

    var last_pos = Vec2{};
    var frame_no: u32 = 0;
    const frames = struct {
        fn run(
            ed: *Editor,
            a: NodeDesc,
            b: NodeDesc,
            mouse: Vec2,
            button: ?bool,
            out_pos: *Vec2,
            counter: *u32,
        ) void {
            counter.* += 1;
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddMousePosEvent(gui_io, mouse.x, mouse.y);
            if (button) |down| ig.ImGuiIO_AddMouseButtonEvent(gui_io, 0, down);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = 800, .y = 600 }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(.{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 800, .y = 600 } });
            out_pos.* = ed.node(a);
            _ = ed.node(b);
            ed.end();
            ig.igEnd();
            ig.igRender();
            const draw = ig.igGetDrawData();
            std.debug.assert(draw != null);
            std.debug.assert(draw.*.TotalVtxCount > 0);
        }
    }.run;

    // first frame: layout only
    frames(&editor, node_a, node_b, .{ .x = 0, .y = 0 }, null, &last_pos, &frame_no);

    // hover the input pin of node a
    frames(&editor, node_a, node_b, .{ .x = 40, .y = 78 }, null, &last_pos, &frame_no);
    try std.testing.expect(editor.hoveredPinRef() != null);
    try std.testing.expectEqual(@as(u64, 1), editor.hoveredPinRef().?.node);
    try std.testing.expectEqual(PinKind.input, editor.hoveredPinRef().?.kind);

    // press on the node body, then move: node() reports the dragged position
    frames(&editor, node_a, node_b, .{ .x = 60, .y = 50 }, true, &last_pos, &frame_no);
    frames(&editor, node_a, node_b, .{ .x = 50, .y = 53 }, false, &last_pos, &frame_no);
    try std.testing.expectApproxEqAbs(@as(f32, 30), last_pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 43), last_pos.y, 0.01);

    // drag a link from node a's output to node b's input
    frames(&editor, node_a, node_b, .{ .x = 236, .y = 78 }, true, &last_pos, &frame_no);
    frames(&editor, node_a, node_b, .{ .x = 300, .y = 78 }, false, &last_pos, &frame_no);
    const edit = editor.takeLinkEdit();
    try std.testing.expect(edit != null);
    const request = if (std.meta.activeTag(edit.?) == .connect) edit.?.connect else return error.ExpectedConnect;
    try std.testing.expectEqual(@as(u64, 1), request.from.node);
    try std.testing.expectEqual(PinKind.output, request.from.kind);
    try std.testing.expectEqual(@as(u64, 2), request.to.node);
    try std.testing.expectEqual(PinKind.input, request.to.kind);
    try std.testing.expect(request.replace == null);
}

test "headless: two-axis scroll pans the canvas" {
    const ctx = ig.igCreateContext(null);
    defer ig.igDestroyContext(ctx);
    ig.igSetCurrentContext(ctx);

    const io = ig.igGetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    _ = ig.ImFontAtlas_Build(io.*.Fonts);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    const step = struct {
        fn run(ed: *Editor, wheel: ?[2]f32) void {
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddMousePosEvent(gui_io, 400, 300);
            if (wheel) |w| ig.ImGuiIO_AddMouseWheelEvent(gui_io, w[0], w[1]);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = 800, .y = 600 }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(.{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 800, .y = 600 } });
            ed.end();
            ig.igEnd();
            ig.igRender();
        }
    }.run;

    step(&editor, null); // establish window hover
    const before = editor.panValue();
    step(&editor, .{ 4, -2 });
    const after = editor.panValue();

    try std.testing.expectApproxEqAbs(before.x + 4 * editor.pan_speed, after.x, 0.01);
    try std.testing.expectApproxEqAbs(before.y - 2 * editor.pan_speed, after.y, 0.01);
}

test "headless: dragging an input link moves its end" {
    const ctx = ig.igCreateContext(null);
    defer ig.igDestroyContext(ctx);
    ig.igSetCurrentContext(ctx);

    const io = ig.igGetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    _ = ig.ImFontAtlas_Build(io.*.Fonts);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    const node_a = NodeDesc{
        .id = 1,
        .pos = .{ .x = 40, .y = 40 },
        .title = "a",
        .outputs = &.{.{ .key = 0, .label = "out" }},
    };
    const node_b = NodeDesc{
        .id = 2,
        .pos = .{ .x = 300, .y = 40 },
        .title = "b",
        .inputs = &.{.{ .key = 0, .label = "in" }},
    };
    const node_c = NodeDesc{
        .id = 3,
        .pos = .{ .x = 560, .y = 40 },
        .title = "c",
        .inputs = &.{.{ .key = 0, .label = "in" }},
    };

    const frames = struct {
        fn run(ed: *Editor, a: NodeDesc, b: NodeDesc, c: NodeDesc, mouse: Vec2, button: ?bool) void {
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddMousePosEvent(gui_io, mouse.x, mouse.y);
            if (button) |down| ig.ImGuiIO_AddMouseButtonEvent(gui_io, 0, down);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = 800, .y = 600 }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(.{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 800, .y = 600 } });
            _ = ed.node(a);
            _ = ed.node(b);
            _ = ed.node(c);
            // the app's model still has a -> b connected
            ed.link(.{
                .from = .{ .node = 1, .index = 0, .kind = .output },
                .to = .{ .node = 2, .index = 0, .kind = .input },
            });
            ed.end();
            ig.igEnd();
            ig.igRender();
        }
    }.run;

    // establish hover
    frames(&editor, node_a, node_b, node_c, .{ .x = 400, .y = 300 }, null);

    // pick up b's input link and drop it on the empty canvas
    frames(&editor, node_a, node_b, node_c, .{ .x = 300, .y = 78 }, true);
    frames(&editor, node_a, node_b, node_c, .{ .x = 620, .y = 400 }, false);
    const dropped = editor.takeLinkEdit();
    try std.testing.expect(dropped != null);
    const dropped_pin = if (std.meta.activeTag(dropped.?) == .disconnect) dropped.?.disconnect else return error.ExpectedDisconnect;
    try std.testing.expectEqual(@as(u64, 2), dropped_pin.node);
    try std.testing.expectEqual(PinKind.input, dropped_pin.kind);

    // pick it up again and rewire it to c
    frames(&editor, node_a, node_b, node_c, .{ .x = 300, .y = 78 }, true);
    frames(&editor, node_a, node_b, node_c, .{ .x = 560, .y = 78 }, false);
    const rewired = editor.takeLinkEdit();
    try std.testing.expect(rewired != null);
    const request = if (std.meta.activeTag(rewired.?) == .connect) rewired.?.connect else return error.ExpectedConnect;
    try std.testing.expectEqual(@as(u64, 1), request.from.node);
    try std.testing.expectEqual(PinKind.output, request.from.kind);
    try std.testing.expectEqual(@as(u64, 3), request.to.node);
    try std.testing.expectEqual(PinKind.input, request.to.kind);
    try std.testing.expect(request.replace != null);
    try std.testing.expectEqual(@as(u64, 2), request.replace.?.node);
    try std.testing.expectEqual(PinKind.input, request.replace.?.kind);
}

test "headless: ctrl+wheel zooms around the cursor" {
    const ctx = ig.igCreateContext(null);
    defer ig.igDestroyContext(ctx);
    ig.igSetCurrentContext(ctx);

    const io = ig.igGetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    _ = ig.ImFontAtlas_Build(io.*.Fonts);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    // deliver a frame's modifier and wheel events in the same frame
    io.*.ConfigInputTrickleEventQueue = false;

    const canvas = Rect{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 800, .y = 600 } };
    const cursor = Vec2{ .x = 500, .y = 200 };

    const step = struct {
        fn run(ed: *Editor, canvas_rect: Rect, mouse: Vec2, wheel: f32, ctrl: bool) void {
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddKeyEvent(gui_io, ig.ImGuiMod_Ctrl, ctrl);
            ig.ImGuiIO_AddMousePosEvent(gui_io, mouse.x, mouse.y);
            ig.ImGuiIO_AddMouseWheelEvent(gui_io, 0, wheel);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = canvas_rect.max.x, .y = canvas_rect.max.y }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(canvas_rect);
            ed.end();
            ig.igEnd();
            ig.igRender();
        }
    }.run;

    // establish window hover and ctrl state
    step(&editor, canvas, cursor, 0, true);
    const zoom_before = editor.zoomValue();
    try std.testing.expectApproxEqAbs(@as(f32, 1), zoom_before, 0.001);

    const pan_before = editor.panValue();
    const world_before = cursor.sub(canvas.min).sub(pan_before).scale(1.0 / zoom_before);

    step(&editor, canvas, cursor, 2, true);
    const zoom_after = editor.zoomValue();
    try std.testing.expect(zoom_after > zoom_before);

    // the graph point under the cursor must not move
    const pan_after = editor.panValue();
    const world_after = cursor.sub(canvas.min).sub(pan_after).scale(1.0 / zoom_after);
    try std.testing.expectApproxEqAbs(world_before.x, world_after.x, 0.01);
    try std.testing.expectApproxEqAbs(world_before.y, world_after.y, 0.01);

    // zoom is clamped
    editor.setZoom(1e6);
    try std.testing.expectEqual(editor.style.zoom_max, editor.zoomValue());
    editor.setZoom(1e-6);
    try std.testing.expectEqual(editor.style.zoom_min, editor.zoomValue());
}

test "headless: node drag and fit respect zoom" {
    const ctx = ig.igCreateContext(null);
    defer ig.igDestroyContext(ctx);
    ig.igSetCurrentContext(ctx);

    const io = ig.igGetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    _ = ig.ImFontAtlas_Build(io.*.Fonts);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    const canvas = Rect{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 800, .y = 600 } };
    const node = NodeDesc{
        .id = 1,
        .pos = .{ .x = 40, .y = 40 },
        .title = "a",
        .inputs = &.{.{ .key = 0, .label = "in" }},
    };

    var last_pos = Vec2{};
    const frames = struct {
        fn run(ed: *Editor, canvas_rect: Rect, desc: NodeDesc, mouse: Vec2, button: ?bool, out_pos: *Vec2) void {
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddMousePosEvent(gui_io, mouse.x, mouse.y);
            if (button) |down| ig.ImGuiIO_AddMouseButtonEvent(gui_io, 0, down);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = canvas_rect.max.x, .y = canvas_rect.max.y }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(canvas_rect);
            out_pos.* = ed.node(desc);
            ed.end();
            ig.igEnd();
            ig.igRender();
        }
    }.run;

    // at 2x, the node at (40, 40) occupies screen (80, 80) onwards
    frames(&editor, canvas, node, .{ .x = 0, .y = 0 }, null, &last_pos);
    editor.zoom = 2;
    editor.setPan(.{});

    frames(&editor, canvas, node, .{ .x = 100, .y = 100 }, null, &last_pos);
    try std.testing.expect(editor.hoveredNodeId() != null);

    // a 20px screen drag is a 10 unit graph drag at 2x
    frames(&editor, canvas, node, .{ .x = 100, .y = 100 }, true, &last_pos);
    frames(&editor, canvas, node, .{ .x = 120, .y = 120 }, false, &last_pos);
    try std.testing.expectApproxEqAbs(@as(f32, 50), last_pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), last_pos.y, 0.01);

    // fit zooms out to bring content back into the canvas
    var far = node;
    far.id = 2;
    far.pos = .{ .x = 2000, .y = 40 };
    last_pos = .{};
    const two_frames = struct {
        fn run(ed: *Editor, canvas_rect: Rect, a: NodeDesc, b: NodeDesc) void {
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddMousePosEvent(gui_io, 0, 0);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = canvas_rect.max.x, .y = canvas_rect.max.y }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(canvas_rect);
            _ = ed.node(a);
            _ = ed.node(b);
            ed.end();
            ig.igEnd();
            ig.igRender();
        }
    }.run;

    two_frames(&editor, canvas, node, far);
    editor.fit();
    try std.testing.expect(editor.zoomValue() < 0.5);

    // both nodes land inside the canvas at the fitted zoom
    const z = editor.zoomValue();
    const pan = editor.panValue();
    try std.testing.expect(pan.x + 0 * z >= 0);
    try std.testing.expect(pan.x + (2000 + editor.style.node_width) * z <= canvas.max.x);
}

test "headless: dragging a selected node moves the whole selection" {
    const ctx = ig.igCreateContext(null);
    defer ig.igDestroyContext(ctx);
    ig.igSetCurrentContext(ctx);

    const io = ig.igGetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    _ = ig.ImFontAtlas_Build(io.*.Fonts);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    const canvas = Rect{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 800, .y = 600 } };
    var a = NodeDesc{ .id = 1, .pos = .{ .x = 40, .y = 40 }, .title = "a" };
    var b = NodeDesc{ .id = 2, .pos = .{ .x = 300, .y = 40 }, .title = "b" };

    const frames = struct {
        fn run(ed: *Editor, canvas_rect: Rect, na: *NodeDesc, nb: *NodeDesc, mouse: Vec2, button: ?bool) void {
            const gui_io = ig.igGetIO();
            ig.ImGuiIO_AddMousePosEvent(gui_io, mouse.x, mouse.y);
            if (button) |down| ig.ImGuiIO_AddMouseButtonEvent(gui_io, 0, down);

            ig.igNewFrame();
            ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always);
            ig.igSetNextWindowSize(.{ .x = canvas_rect.max.x, .y = canvas_rect.max.y }, ig.ImGuiCond_Always);
            _ = ig.igBegin("test", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoSavedSettings);
            ed.begin(canvas_rect);
            na.pos = ed.node(na.*);
            nb.pos = ed.node(nb.*);
            ed.end();
            ig.igEnd();
            ig.igRender();
        }
    }.run;

    frames(&editor, canvas, &a, &b, .{ .x = 600, .y = 300 }, null); // establish hover

    // box-select both nodes
    frames(&editor, canvas, &a, &b, .{ .x = 0, .y = 0 }, true);
    frames(&editor, canvas, &a, &b, .{ .x = 600, .y = 200 }, false);
    try std.testing.expectEqual(@as(usize, 2), editor.selectedNodes().len);

    // dragging one of them carries the other along
    frames(&editor, canvas, &a, &b, .{ .x = 60, .y = 50 }, true);
    frames(&editor, canvas, &a, &b, .{ .x = 70, .y = 53 }, false);
    try std.testing.expectApproxEqAbs(@as(f32, 50), a.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 43), a.pos.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 310), b.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 43), b.pos.y, 0.01);
}
