//! CUI theme: the old "Nuklear Dark Gray" ImGui palette, mapped onto CUI's
//! semantic tokens. Applied once after `cui_create`, before the first frame.

const std = @import("std");
const cui = @import("cui");

/// sRGB float -> 8-bit component.
fn channel(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
}

fn col(r: f32, g: f32, b: f32, a: f32) cui.cui_color {
    return .{ .r = channel(r), .g = channel(g), .b = channel(b), .a = channel(a) };
}

fn set(th: *cui.cui_theme, token: c_int, color: cui.cui_color) void {
    th.colors[@intCast(token)] = color;
}

pub fn apply(ui: *cui.cui_ctx) void {
    const maybe_th = cui.cui_theme_get(ui);
    if (maybe_th == null) return;
    const th: *cui.cui_theme = maybe_th;

    // Surfaces: window 0.18, controls 0.15, raised panels 0.22.
    set(th, cui.CUI_TOKEN_BACKGROUND, col(0.18, 0.18, 0.18, 1.0));
    set(th, cui.CUI_TOKEN_SURFACE, col(0.18, 0.18, 0.18, 1.0));
    set(th, cui.CUI_TOKEN_SURFACE_RAISED, col(0.22, 0.22, 0.22, 1.0));
    set(th, cui.CUI_TOKEN_SURFACE_MUTED, col(0.15, 0.15, 0.15, 1.0));

    // Text: 0.69 body, 0.35 disabled.
    set(th, cui.CUI_TOKEN_FOREGROUND, col(0.69, 0.69, 0.69, 1.0));
    set(th, cui.CUI_TOKEN_TEXT_SECONDARY, col(0.55, 0.55, 0.55, 1.0));
    set(th, cui.CUI_TOKEN_TEXT_MUTED, col(0.35, 0.35, 0.35, 1.0));

    set(th, cui.CUI_TOKEN_BORDER, col(0.22, 0.22, 0.22, 1.0));
    set(th, cui.CUI_TOKEN_BORDER_SUBTLE, col(0.22, 0.22, 0.22, 0.5));
    set(th, cui.CUI_TOKEN_BORDER_STRONG, col(0.29, 0.29, 0.29, 1.0));

    // Grayscale accent; the old style had no hue except the text selection.
    set(th, cui.CUI_TOKEN_ACCENT, col(0.40, 0.40, 0.40, 1.0));
    set(th, cui.CUI_TOKEN_ACCENT_STRONG, col(0.59, 0.59, 0.59, 1.0));
    set(th, cui.CUI_TOKEN_ACCENT_SUBTLE, col(0.40, 0.40, 0.40, 0.18));
    set(th, cui.CUI_TOKEN_ACCENT_FOREGROUND, col(0.15, 0.15, 0.15, 1.0));
    set(th, cui.CUI_TOKEN_FOCUS_RING, col(0.26, 0.59, 0.98, 0.9));

    // Controls: check mark 0.69, frame 0.15, hovered 0.29, active 0.39.
    set(th, cui.CUI_TOKEN_CONTROL_ON, col(0.69, 0.69, 0.69, 1.0));
    set(th, cui.CUI_TOKEN_CONTROL_GLYPH, col(0.15, 0.15, 0.15, 1.0));
    set(th, cui.CUI_TOKEN_CONTROL_TRACK, col(0.15, 0.15, 0.15, 1.0));
    set(th, cui.CUI_TOKEN_CONTROL_TRACK_HOVER, col(0.29, 0.29, 0.29, 1.0));
    set(th, cui.CUI_TOKEN_CONTROL_THUMB, col(0.40, 0.40, 0.40, 1.0));
    set(th, cui.CUI_TOKEN_CONTROL_THUMB_ON, col(0.15, 0.15, 0.15, 1.0));

    set(th, cui.CUI_TOKEN_HOVER, col(0.22, 0.22, 0.22, 0.78));
    set(th, cui.CUI_TOKEN_ACTIVE, col(0.29, 0.29, 0.29, 0.78));
    set(th, cui.CUI_TOKEN_SCRIM, col(0.0, 0.0, 0.0, 0.55));

    // No rounded corners, no drop shadows; the old style was flat.
    th.radius_control = 0;
    th.radius_panel = 0;
    th.radius_surface = 0;

    for (&th.shadow_resting) |*shadow| shadow.* = .{ .y = 0, .blur = 0, .spread = 0, .alpha = 0 };
    for (&th.shadow_raised) |*shadow| shadow.* = .{ .y = 0, .blur = 0, .spread = 0, .alpha = 0 };
    for (&th.shadow_floating) |*shadow| shadow.* = .{ .y = 0, .blur = 0, .spread = 0, .alpha = 0 };

    // Tight controls and text, matching ImGui's 13 px body / 4 px frame pad.
    th.control_sm = 24;
    th.control_md = 28;
    th.control_lg = 32;
    th.text_xs = 10;
    th.text_sm = 11;
    th.text_body = 13;
    th.text_lg = 14;
    th.heading = .{ 26, 20, 16, 14 };
}