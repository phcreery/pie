//! The darkroom view: the image view's input handling plus the modules panel.
//!
//! The image itself is blitted by the host (`src/app/blit.zig`) using the
//! zoom/pan this view maintains, so what lives here is exactly what benefits
//! from hot reloading: widget and view composition.

const std = @import("std");

const sokol = @import("sokol");
const sapp = sokol.app;

const abi = @import("abi");
const ModulesPanel = @import("../components/modules_panel.zig").ModulesPanel;

pub const Darkroom = struct {
    pub fn draw(state: *abi.SharedState, model: *const abi.Model) void {
        ModulesPanel.draw(state, model);
    }

    /// Pan (left-drag) and zoom (wheel) for the image view. The host reads the
    /// resulting `zoom`/`pan` when it draws the image.
    pub fn event(state: *abi.SharedState, ev: [*c]const sapp.Event) void {
        if (ev == null) return;
        const e = ev[0];
        switch (e.type) {
            .MOUSE_DOWN => {
                if (e.mouse_button == .LEFT) {
                    state.dragging = true;
                    state.last_mouse = .{ e.mouse_x, e.mouse_y };
                }
            },
            .MOUSE_UP => {
                if (e.mouse_button == .LEFT) state.dragging = false;
            },
            .MOUSE_MOVE => {
                if (state.dragging) {
                    const ww = @as(f32, @floatFromInt(e.framebuffer_width));
                    const wh = @as(f32, @floatFromInt(e.framebuffer_height));
                    if (ww > 0 and wh > 0) {
                        const dx_ndc = (e.mouse_x - state.last_mouse[0]) / (ww * 0.5);
                        const dy_ndc = -(e.mouse_y - state.last_mouse[1]) / (wh * 0.5);
                        state.pan[0] += dx_ndc;
                        state.pan[1] += dy_ndc;
                    }
                    state.last_mouse = .{ e.mouse_x, e.mouse_y };
                }
            },
            .MOUSE_SCROLL => {
                const factor = std.math.pow(f32, 1.1, -e.scroll_y);
                state.last_zoom = state.zoom;
                state.zoom = std.math.clamp(state.zoom * factor, 0.05, 64.0);

                // Zoom toward the cursor
                const ww = @as(f32, @floatFromInt(e.framebuffer_width));
                const wh = @as(f32, @floatFromInt(e.framebuffer_height));
                if (ww > 0 and wh > 0 and state.last_zoom > 0) {
                    // cursor in NDC (screen center = 0, y up)
                    const cx = (e.mouse_x - (ww * 0.5)) / (ww * 0.5);
                    const cy = -(e.mouse_y - (wh * 0.5)) / (wh * 0.5);
                    const r = state.zoom / state.last_zoom;
                    state.pan[0] += (1.0 - r) * (cx - state.pan[0]);
                    state.pan[1] += (1.0 - r) * (cy - state.pan[1]);
                }
            },
            else => {},
        }
    }
};
