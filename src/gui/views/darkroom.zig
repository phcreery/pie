//! The darkroom view: the image view's input handling plus the modules panel.
//!
//! The image itself is blitted by the app (`src/app/blit.zig`) using the
//! zoom/pan this view maintains.

const std = @import("std");

const sokol = @import("sokol");
const sapp = sokol.app;

const session = @import("session");
const ModulesPanel = @import("../components/modules_panel.zig").ModulesPanel;

pub const Darkroom = struct {
    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    dragging: bool = false,
    last_mouse: [2]f32 = .{ 0, 0 },
    last_zoom: f32 = 1,
    panel_open: bool = true,

    pub fn draw(self: *Darkroom, s: *session.Session) void {
        ModulesPanel.draw(s, &self.panel_open);
    }

    /// Pan (left-drag) and zoom (wheel) for the image view. The app reads the
    /// resulting `zoom`/`pan` when it draws the image.
    pub fn event(self: *Darkroom, ev: [*c]const sapp.Event) void {
        if (ev == null) return;
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
                    const ww = @as(f32, @floatFromInt(e.framebuffer_width));
                    const wh = @as(f32, @floatFromInt(e.framebuffer_height));
                    if (ww > 0 and wh > 0) {
                        const dx_ndc = (e.mouse_x - self.last_mouse[0]) / (ww * 0.5);
                        const dy_ndc = -(e.mouse_y - self.last_mouse[1]) / (wh * 0.5);
                        self.pan[0] += dx_ndc;
                        self.pan[1] += dy_ndc;
                    }
                    self.last_mouse = .{ e.mouse_x, e.mouse_y };
                }
            },
            .MOUSE_SCROLL => {
                const factor = std.math.pow(f32, 1.1, -e.scroll_y);
                self.last_zoom = self.zoom;
                self.zoom = std.math.clamp(self.zoom * factor, 0.05, 64.0);

                // Zoom toward the cursor
                const ww = @as(f32, @floatFromInt(e.framebuffer_width));
                const wh = @as(f32, @floatFromInt(e.framebuffer_height));
                if (ww > 0 and wh > 0 and self.last_zoom > 0) {
                    // cursor in NDC (screen center = 0, y up)
                    const cx = (e.mouse_x - (ww * 0.5)) / (ww * 0.5);
                    const cy = -(e.mouse_y - (wh * 0.5)) / (wh * 0.5);
                    const r = self.zoom / self.last_zoom;
                    self.pan[0] += (1.0 - r) * (cx - self.pan[0]);
                    self.pan[1] += (1.0 - r) * (cy - self.pan[1]);
                }
            },
            else => {},
        }
    }
};
