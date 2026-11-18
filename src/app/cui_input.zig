//! Translate sokol-app events into CUI input.
//!
//! CUI wants points (logical pixels) and scroll in lines. Sokol reports mouse
//! positions in framebuffer pixels and precise scroll deltas scaled by 0.1.

const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const cui = @import("cui");

pub fn handle(ui: *cui.cui_ctx, ev: sapp.Event) void {
    const dpi = if (sapp.dpiScale() > 0) sapp.dpiScale() else 1;

    switch (ev.type) {
        .MOUSE_MOVE => cui.cui_input_mouse_move(ui, ev.mouse_x / dpi, ev.mouse_y / dpi),
        .MOUSE_DOWN, .MOUSE_UP => {
            cui.cui_input_mouse_move(ui, ev.mouse_x / dpi, ev.mouse_y / dpi);
            const button: cui.cui_mouse_button = @intCast(switch (ev.mouse_button) {
                .LEFT => cui.CUI_MOUSE_LEFT,
                .RIGHT => cui.CUI_MOUSE_RIGHT,
                .MIDDLE => cui.CUI_MOUSE_MIDDLE,
                else => return,
            });
            cui.cui_input_mouse_button(ui, button, ev.type == .MOUSE_DOWN);
        },
        .MOUSE_SCROLL => {
            cui.cui_input_scroll(ui, scrollLines(ev.scroll_x), scrollLines(ev.scroll_y));
        },
        .MOUSE_LEAVE => cui.cui_input_mouse_leave(ui),
        .FOCUSED => cui.cui_input_focus(ui, true),
        .UNFOCUSED => cui.cui_input_focus(ui, false),
        .KEY_DOWN, .KEY_UP => {
            const key = mapKey(ev.key_code) orelse return;
            cui.cui_input_key(ui, key, ev.type == .KEY_DOWN, mods(ev.modifiers));
        },
        .CHAR => {
            if (ev.char_code == 0) return;
            var buf: [4]u8 = @splat(0);
            const len = std.unicode.utf8Encode(@intCast(ev.char_code), &buf) catch return;
            buf[len] = 0;
            cui.cui_input_text(ui, &buf);
        },
        else => {},
    }
}

/// Trackpads report precise deltas: sokol scales the point delta by 0.1 and
/// CUI expects points / 44 lines. A wheel notch arrives as whole lines, which
/// are passed through unchanged.
fn scrollLines(delta: f32) f32 {
    if (delta == 0) return 0;
    if (delta == @trunc(delta) and @abs(delta) >= 1.0) return delta;
    return delta * 10.0 / 44.0;
}

fn mods(m: u32) c_int {
    var out: c_int = 0;
    if (m & sapp.modifier_shift != 0) out |= cui.CUI_MOD_SHIFT;
    if (m & sapp.modifier_ctrl != 0) out |= cui.CUI_MOD_CTRL;
    if (m & sapp.modifier_alt != 0) out |= cui.CUI_MOD_ALT;
    if (m & sapp.modifier_super != 0) out |= cui.CUI_MOD_SUPER;
    return out;
}

pub fn setCursor(cursor: cui.cui_cursor) void {
    const mapped: sapp.MouseCursor = switch (cursor) {
        cui.CUI_CURSOR_ARROW => .ARROW,
        cui.CUI_CURSOR_HAND => .POINTING_HAND,
        cui.CUI_CURSOR_TEXT => .IBEAM,
        cui.CUI_CURSOR_RESIZE_EW => .RESIZE_EW,
        cui.CUI_CURSOR_RESIZE_NS => .RESIZE_NS,
        cui.CUI_CURSOR_MOVE => .RESIZE_ALL,
        cui.CUI_CURSOR_NOT_ALLOWED => .NOT_ALLOWED,
        else => .ARROW,
    };
    sapp.setMouseCursor(mapped);
}

fn mapKey(key: sapp.Keycode) ?cui.cui_key {
    const k: c_int = switch (key) {
        .TAB => cui.CUI_KEY_TAB,
        .ENTER => cui.CUI_KEY_ENTER,
        .ESCAPE => cui.CUI_KEY_ESCAPE,
        .BACKSPACE => cui.CUI_KEY_BACKSPACE,
        .DELETE => cui.CUI_KEY_DELETE,
        .SPACE => cui.CUI_KEY_SPACE,
        .LEFT => cui.CUI_KEY_LEFT,
        .RIGHT => cui.CUI_KEY_RIGHT,
        .UP => cui.CUI_KEY_UP,
        .DOWN => cui.CUI_KEY_DOWN,
        .HOME => cui.CUI_KEY_HOME,
        .END => cui.CUI_KEY_END,
        .PAGE_UP => cui.CUI_KEY_PAGE_UP,
        .PAGE_DOWN => cui.CUI_KEY_PAGE_DOWN,
        .A => cui.CUI_KEY_A,
        .B => cui.CUI_KEY_B,
        .C => cui.CUI_KEY_C,
        .D => cui.CUI_KEY_D,
        .E => cui.CUI_KEY_E,
        .F => cui.CUI_KEY_F,
        .G => cui.CUI_KEY_G,
        .H => cui.CUI_KEY_H,
        .I => cui.CUI_KEY_I,
        .J => cui.CUI_KEY_J,
        .K => cui.CUI_KEY_K,
        .L => cui.CUI_KEY_L,
        .M => cui.CUI_KEY_M,
        .N => cui.CUI_KEY_N,
        .O => cui.CUI_KEY_O,
        .P => cui.CUI_KEY_P,
        .Q => cui.CUI_KEY_Q,
        .R => cui.CUI_KEY_R,
        .S => cui.CUI_KEY_S,
        .T => cui.CUI_KEY_T,
        .U => cui.CUI_KEY_U,
        .V => cui.CUI_KEY_V,
        .W => cui.CUI_KEY_W,
        .X => cui.CUI_KEY_X,
        .Y => cui.CUI_KEY_Y,
        .Z => cui.CUI_KEY_Z,
        ._0 => cui.CUI_KEY_0,
        ._1 => cui.CUI_KEY_1,
        ._2 => cui.CUI_KEY_2,
        ._3 => cui.CUI_KEY_3,
        ._4 => cui.CUI_KEY_4,
        ._5 => cui.CUI_KEY_5,
        ._6 => cui.CUI_KEY_6,
        ._7 => cui.CUI_KEY_7,
        ._8 => cui.CUI_KEY_8,
        ._9 => cui.CUI_KEY_9,
        .MINUS => cui.CUI_KEY_MINUS,
        .EQUAL => cui.CUI_KEY_EQUAL,
        .COMMA => cui.CUI_KEY_COMMA,
        .PERIOD => cui.CUI_KEY_PERIOD,
        .SLASH => cui.CUI_KEY_SLASH,
        .F1 => cui.CUI_KEY_F1,
        .F2 => cui.CUI_KEY_F2,
        .F3 => cui.CUI_KEY_F3,
        .F4 => cui.CUI_KEY_F4,
        .F5 => cui.CUI_KEY_F5,
        .F6 => cui.CUI_KEY_F6,
        .F7 => cui.CUI_KEY_F7,
        .F8 => cui.CUI_KEY_F8,
        .F9 => cui.CUI_KEY_F9,
        .F10 => cui.CUI_KEY_F10,
        .F11 => cui.CUI_KEY_F11,
        .F12 => cui.CUI_KEY_F12,
        else => return null,
    };
    return @intCast(k);
}
