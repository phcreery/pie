//! The darkroom view: a split of the modules panel (left) and the image
//! (right). The splitter between them is draggable.
//!
//! The image itself is blitted by the app (`src/app/blit.zig`) into
//! `image_rect` using the zoom/pan this view maintains. `layout` is called
//! once per frame, before the blit, so the panel and the image agree on where
//! the split is.

const std = @import("std");

const sokol = @import("sokol");
const sapp = sokol.app;
const ig = @import("cimgui");

const session = @import("session");
const ModulesPanel = @import("../components/modules_panel.zig").ModulesPanel;
const GraphView = @import("./graph.zig").GraphView;

pub const Mode = enum { image, graph };

pub const Darkroom = struct {
    /// width of the draggable gap between the panel and the image
    const splitter_w: f32 = 6;
    const min_panel_w: f32 = 180;
    const min_image_w: f32 = 160;
    /// height of the mode switch strip above the content
    const toolbar_h: f32 = 28;

    /// Image or node graph in the content area.
    mode: Mode = .image,
    graph: GraphView,

    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    dragging: bool = false,
    last_mouse: [2]f32 = .{ 0, 0 },
    last_zoom: f32 = 1,

    /// left panel visibility, toggled from the menu bar
    panel_open: bool = true,
    /// left panel width in imgui logical units, dragged by the splitter
    panel_w: f32 = 340,

    /// main viewport's work area (below the menu bar), imgui logical units
    work_pos: [2]f32 = .{ 0, 0 },
    work_size: [2]f32 = .{ 0, 0 },
    /// region the image may draw into, framebuffer pixels
    image_rect: session.Rect = .{},
    /// region the node graph draws into, imgui logical units
    graph_rect: session.Rect = .{},

    pub fn init(allocator: std.mem.Allocator) Darkroom {
        return .{ .graph = GraphView.init(allocator) };
    }

    pub fn deinit(self: *Darkroom) void {
        self.graph.deinit();
    }

    /// Lay out the split for the current viewport. Runs before the image is
    /// blitted so both the blit and the widgets use the same regions.
    pub fn layout(self: *Darkroom) void {
        const viewport = ig.igGetMainViewport();
        self.work_pos = .{ viewport.*.WorkPos.x, viewport.*.WorkPos.y };
        self.work_size = .{ viewport.*.WorkSize.x, viewport.*.WorkSize.y };

        const content_y = self.work_pos[1] + toolbar_h;
        const content_h = @max(0, self.work_size[1] - toolbar_h);

        var panel: f32 = 0;
        if (self.panel_open and self.work_size[0] > min_panel_w + splitter_w + min_image_w) {
            self.panel_w = std.math.clamp(self.panel_w, min_panel_w, self.work_size[0] - splitter_w - min_image_w);
            panel = self.panel_w + splitter_w;
        }

        // imgui works in logical units, the blit in framebuffer pixels
        const dpi = sapp.dpiScale();
        self.image_rect = .{
            .x = (self.work_pos[0] + panel) * dpi,
            .y = content_y * dpi,
            .w = (self.work_size[0] - panel) * dpi,
            .h = content_h * dpi,
        };
        self.graph_rect = .{
            .x = self.work_pos[0] + panel,
            .y = content_y,
            .w = self.work_size[0] - panel,
            .h = content_h,
        };
    }

    pub fn draw(self: *Darkroom, s: *session.Session) void {
        self.drawToolbar();
        if (self.panel_open) {
            ModulesPanel.draw(s, .{
                .x = self.work_pos[0],
                .y = self.work_pos[1] + toolbar_h,
                .w = self.panel_w,
                .h = self.work_size[1] - toolbar_h,
            });
            self.drawSplitter();
        }
        if (self.mode == .graph) self.graph.draw(s, self.graph_rect);
    }

    /// The darkroom's own mode switch: image vs. node graph.
    fn drawToolbar(self: *Darkroom) void {
        const flags = ig.ImGuiWindowFlags_NoTitleBar |
            ig.ImGuiWindowFlags_NoResize |
            ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoScrollbar |
            ig.ImGuiWindowFlags_NoScrollWithMouse |
            ig.ImGuiWindowFlags_NoSavedSettings |
            ig.ImGuiWindowFlags_NoBringToFrontOnFocus;

        ig.igSetNextWindowPos(.{ .x = self.work_pos[0], .y = self.work_pos[1] }, ig.ImGuiCond_Always);
        ig.igSetNextWindowSize(.{ .x = self.work_size[0], .y = toolbar_h }, ig.ImGuiCond_Always);
        if (!ig.igBegin("##darkroom_toolbar", null, flags)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        if (self.modeButton("Image", self.mode == .image)) self.mode = .image;
        ig.igSameLineEx(0, 8);
        if (self.modeButton("Graph", self.mode == .graph)) self.mode = .graph;

        if (self.mode == .graph) {
            ig.igSameLineEx(0, 16);
            if (ig.igButton("Fit")) self.graph.requestFit();
            ig.igSameLineEx(0, 12);
            ig.igTextDisabled("%s", "drag a pin to connect, Delete removes, scroll pans, cmd/ctrl+scroll zooms");
        }
    }

    fn modeButton(self: *Darkroom, label: [*c]const u8, active: bool) bool {
        _ = self;
        if (active) {
            ig.igPushStyleColor(ig.ImGuiCol_Button, ig.igGetColorU32(ig.ImGuiCol_ButtonActive));
            defer ig.igPopStyleColor();
            return ig.igButton(label);
        }
        return ig.igButton(label);
    }

    /// A narrow, transparent strip holding the drag handle between the panel
    /// and the image.
    fn drawSplitter(self: *Darkroom) void {
        const x = self.work_pos[0] + self.panel_w;
        const y = self.work_pos[1] + toolbar_h;
        const h = self.work_size[1] - toolbar_h;

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
        ig.igSetNextWindowPos(.{ .x = x, .y = y }, ig.ImGuiCond_Always);
        ig.igSetNextWindowSize(.{ .x = splitter_w, .y = h }, ig.ImGuiCond_Always);
        if (!ig.igBegin("##splitter", null, flags)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        _ = ig.igInvisibleButton("##grip", .{ .x = splitter_w, .y = h }, ig.ImGuiButtonFlags_None);
        if (ig.igIsItemActive()) {
            const max_panel = @max(min_panel_w, self.work_size[0] - splitter_w - min_image_w);
            self.panel_w = std.math.clamp(self.panel_w + ig.igGetIO().*.MouseDelta.x, min_panel_w, max_panel);
        }
        if (ig.igIsItemHovered(ig.ImGuiHoveredFlags_None)) {
            ig.igSetMouseCursor(ig.ImGuiMouseCursor_ResizeEW);
        }

        // a hairline so the split is visible against the image
        const mid = x + splitter_w * 0.5;
        const color = ig.igGetColorU32Ex(ig.ImGuiCol_Separator, 1);
        ig.ImDrawList_AddLine(ig.igGetWindowDrawList(), .{ .x = mid, .y = y }, .{ .x = mid, .y = y + h }, color);
    }

    /// Pan (left-drag) and zoom (wheel) for the image view. The app reads the
    /// resulting `zoom`/`pan` when it draws the image. Positions come in
    /// framebuffer pixels, matching `image_rect`.
    pub fn event(self: *Darkroom, ev: [*c]const sapp.Event) void {
        if (ev == null) return;
        // the graph consumes its input through ImGui; raw pan/zoom is for the image
        if (self.mode != .image) return;
        const e = ev[0];
        switch (e.type) {
            .MOUSE_DOWN => {
                if (e.mouse_button == .LEFT) {
                    self.dragging = true;
                    self.last_mouse = .{ e.mouse_x, e.mouse_y };
                }
            },
            .MOUSE_UP => {
                if (e.mouse_button == .LEFT) self.dragging = false;
            },
            .MOUSE_MOVE => {
                if (self.dragging) {
                    const rect = self.image_rect;
                    if (rect.w > 0 and rect.h > 0) {
                        const dx = (e.mouse_x - self.last_mouse[0]) / (rect.w * 0.5);
                        const dy = -(e.mouse_y - self.last_mouse[1]) / (rect.h * 0.5);
                        self.pan[0] += dx;
                        self.pan[1] += dy;
                    }
                    self.last_mouse = .{ e.mouse_x, e.mouse_y };
                }
            },
            .MOUSE_SCROLL => {
                const factor = std.math.pow(f32, 1.1, -e.scroll_y);
                self.last_zoom = self.zoom;
                self.zoom = std.math.clamp(self.zoom * factor, 0.05, 64.0);

                // zoom toward the cursor, in the image region's coordinates
                const rect = self.image_rect;
                if (rect.w > 0 and rect.h > 0 and self.last_zoom > 0) {
                    const cx = (e.mouse_x - (rect.x + rect.w * 0.5)) / (rect.w * 0.5);
                    const cy = -(e.mouse_y - (rect.y + rect.h * 0.5)) / (rect.h * 0.5);
                    const ratio = self.zoom / self.last_zoom;
                    self.pan[0] += (1.0 - ratio) * (cx - self.pan[0]);
                    self.pan[1] += (1.0 - ratio) * (cy - self.pan[1]);
                }
            },
            else => {},
        }
    }
};
