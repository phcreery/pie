//! ImGui theme: a port of the "Nuklear Dark Gray" style in `gui/theme.md`.
//!
//! Applied once at startup, before the first frame. `igGetStyle` hands back the
//! global style instance, which Dear ImGui only allows poking between frames.

const ig = @import("cimgui");

/// One `ImGuiCol_` slot and its RGBA value.
const Entry = struct {
    id: c_int,
    rgba: [4]f32,
};

/// Colors transcribed from the reference style, in `ImGuiCol_` order.
const entries = [_]Entry{
    .{ .id = ig.ImGuiCol_Text, .rgba = .{ 0.69, 0.69, 0.69, 1.00 } },
    .{ .id = ig.ImGuiCol_TextDisabled, .rgba = .{ 0.35, 0.35, 0.35, 1.00 } },
    .{ .id = ig.ImGuiCol_WindowBg, .rgba = .{ 0.18, 0.18, 0.18, 1.00 } },
    .{ .id = ig.ImGuiCol_ChildBg, .rgba = .{ 0.00, 0.00, 0.00, 0.00 } },
    .{ .id = ig.ImGuiCol_PopupBg, .rgba = .{ 0.18, 0.18, 0.18, 1.00 } },
    .{ .id = ig.ImGuiCol_Border, .rgba = .{ 0.22, 0.22, 0.22, 1.00 } },
    .{ .id = ig.ImGuiCol_BorderShadow, .rgba = .{ 0.00, 0.00, 0.00, 0.00 } },
    .{ .id = ig.ImGuiCol_FrameBg, .rgba = .{ 0.15, 0.15, 0.15, 1.00 } },
    .{ .id = ig.ImGuiCol_FrameBgHovered, .rgba = .{ 0.29, 0.29, 0.29, 1.00 } },
    .{ .id = ig.ImGuiCol_FrameBgActive, .rgba = .{ 0.39, 0.39, 0.39, 1.00 } },
    .{ .id = ig.ImGuiCol_TitleBg, .rgba = .{ 0.15, 0.15, 0.15, 1.00 } },
    .{ .id = ig.ImGuiCol_TitleBgActive, .rgba = .{ 0.18, 0.18, 0.18, 1.00 } },
    .{ .id = ig.ImGuiCol_TitleBgCollapsed, .rgba = .{ 0.15, 0.15, 0.15, 1.00 } },
    .{ .id = ig.ImGuiCol_MenuBarBg, .rgba = .{ 0.14, 0.14, 0.14, 1.00 } },
    .{ .id = ig.ImGuiCol_ScrollbarBg, .rgba = .{ 0.18, 0.18, 0.18, 1.00 } },
    .{ .id = ig.ImGuiCol_ScrollbarGrab, .rgba = .{ 0.31, 0.31, 0.31, 1.00 } },
    .{ .id = ig.ImGuiCol_ScrollbarGrabHovered, .rgba = .{ 0.41, 0.41, 0.41, 1.00 } },
    .{ .id = ig.ImGuiCol_ScrollbarGrabActive, .rgba = .{ 0.51, 0.51, 0.51, 1.00 } },
    .{ .id = ig.ImGuiCol_CheckMark, .rgba = .{ 0.69, 0.69, 0.69, 1.00 } },
    .{ .id = ig.ImGuiCol_CheckboxSelectedBg, .rgba = .{ 0.15, 0.15, 0.15, 0.50 } },
    .{ .id = ig.ImGuiCol_SliderGrab, .rgba = .{ 0.40, 0.40, 0.40, 1.00 } },
    .{ .id = ig.ImGuiCol_SliderGrabActive, .rgba = .{ 0.59, 0.59, 0.59, 1.00 } },
    .{ .id = ig.ImGuiCol_Button, .rgba = .{ 0.22, 0.22, 0.22, 1.00 } },
    .{ .id = ig.ImGuiCol_ButtonHovered, .rgba = .{ 0.15, 0.15, 0.15, 1.00 } },
    .{ .id = ig.ImGuiCol_ButtonActive, .rgba = .{ 0.12, 0.12, 0.12, 1.00 } },
    .{ .id = ig.ImGuiCol_Header, .rgba = .{ 0.18, 0.18, 0.18, 0.00 } },
    .{ .id = ig.ImGuiCol_HeaderHovered, .rgba = .{ 0.22, 0.22, 0.22, 0.78 } },
    .{ .id = ig.ImGuiCol_HeaderActive, .rgba = .{ 0.29, 0.29, 0.29, 0.78 } },
    .{ .id = ig.ImGuiCol_Separator, .rgba = .{ 0.29, 0.29, 0.29, 0.50 } },
    .{ .id = ig.ImGuiCol_SeparatorHovered, .rgba = .{ 0.49, 0.49, 0.49, 0.78 } },
    .{ .id = ig.ImGuiCol_SeparatorActive, .rgba = .{ 0.69, 0.69, 0.69, 1.00 } },
    .{ .id = ig.ImGuiCol_ResizeGrip, .rgba = .{ 0.29, 0.29, 0.29, 1.00 } },
    .{ .id = ig.ImGuiCol_ResizeGripHovered, .rgba = .{ 0.49, 0.49, 0.49, 1.00 } },
    .{ .id = ig.ImGuiCol_ResizeGripActive, .rgba = .{ 0.69, 0.69, 0.69, 1.00 } },
    .{ .id = ig.ImGuiCol_InputTextCursor, .rgba = .{ 0.78, 0.78, 0.78, 1.00 } },
    .{ .id = ig.ImGuiCol_TabHovered, .rgba = .{ 0.49, 0.49, 0.49, 0.80 } },
    .{ .id = ig.ImGuiCol_Tab, .rgba = .{ 0.29, 0.29, 0.29, 1.00 } },
    .{ .id = ig.ImGuiCol_TabSelected, .rgba = .{ 0.39, 0.39, 0.39, 1.00 } },
    .{ .id = ig.ImGuiCol_TabSelectedOverline, .rgba = .{ 0.15, 0.15, 0.15, 1.00 } },
    .{ .id = ig.ImGuiCol_TabDimmed, .rgba = .{ 0.29, 0.29, 0.29, 0.78 } },
    .{ .id = ig.ImGuiCol_TabDimmedSelected, .rgba = .{ 0.39, 0.39, 0.39, 0.78 } },
    .{ .id = ig.ImGuiCol_TabDimmedSelectedOverline, .rgba = .{ 0.50, 0.50, 0.50, 0.00 } },
    .{ .id = ig.ImGuiCol_PlotLines, .rgba = .{ 0.61, 0.61, 0.61, 1.00 } },
    .{ .id = ig.ImGuiCol_PlotLinesHovered, .rgba = .{ 1.00, 0.43, 0.35, 1.00 } },
    .{ .id = ig.ImGuiCol_PlotHistogram, .rgba = .{ 0.90, 0.70, 0.00, 1.00 } },
    .{ .id = ig.ImGuiCol_PlotHistogramHovered, .rgba = .{ 1.00, 0.60, 0.00, 1.00 } },
    .{ .id = ig.ImGuiCol_TableHeaderBg, .rgba = .{ 0.19, 0.19, 0.20, 1.00 } },
    .{ .id = ig.ImGuiCol_TableBorderStrong, .rgba = .{ 0.29, 0.29, 0.29, 1.00 } },
    .{ .id = ig.ImGuiCol_TableBorderLight, .rgba = .{ 0.29, 0.29, 0.29, 0.50 } },
    .{ .id = ig.ImGuiCol_TableRowBg, .rgba = .{ 0.00, 0.00, 0.00, 0.00 } },
    .{ .id = ig.ImGuiCol_TableRowBgAlt, .rgba = .{ 1.00, 1.00, 1.00, 0.06 } },
    .{ .id = ig.ImGuiCol_TextLink, .rgba = .{ 0.29, 0.50, 1.00, 1.00 } },
    .{ .id = ig.ImGuiCol_TextSelectedBg, .rgba = .{ 0.26, 0.59, 0.98, 0.35 } },
    .{ .id = ig.ImGuiCol_TreeLines, .rgba = .{ 0.43, 0.43, 0.50, 0.50 } },
    .{ .id = ig.ImGuiCol_DragDropTarget, .rgba = .{ 1.00, 1.00, 0.00, 0.90 } },
    .{ .id = ig.ImGuiCol_DragDropTargetBg, .rgba = .{ 0.00, 0.00, 0.00, 0.00 } },
    .{ .id = ig.ImGuiCol_UnsavedMarker, .rgba = .{ 0.69, 0.69, 0.69, 1.00 } },
    .{ .id = ig.ImGuiCol_NavCursor, .rgba = .{ 0.98, 0.98, 0.98, 1.00 } },
    .{ .id = ig.ImGuiCol_NavWindowingHighlight, .rgba = .{ 1.00, 1.00, 1.00, 0.70 } },
    .{ .id = ig.ImGuiCol_NavWindowingDimBg, .rgba = .{ 0.80, 0.80, 0.80, 0.20 } },
    .{ .id = ig.ImGuiCol_ModalWindowDimBg, .rgba = .{ 0.80, 0.80, 0.80, 0.35 } },
};

pub fn apply() void {
    const style: *ig.ImGuiStyle = ig.igGetStyle();

    style.WindowBorderSize = 1.0;
    style.ChildBorderSize = 1.0;
    style.PopupBorderSize = 1.0;
    style.FrameBorderSize = 1.0;

    // style.WindowRounding = 2.0;
    // style.ChildRounding = 2.0;
    // style.FrameRounding = 2.0;
    // style.PopupRounding = 2.0;
    // style.GrabRounding = 2.0;

    for (entries) |entry| set(style, entry.id, entry.rgba);

    // the docking colors only exist in the docking-branch header
    if (comptime @hasDecl(ig, "ImGuiCol_DockingPreview")) applyDocking(style);
}

fn applyDocking(style: *ig.ImGuiStyle) void {
    set(style, ig.ImGuiCol_DockingPreview, .{ 0.69, 0.69, 0.69, 0.78 });
    set(style, ig.ImGuiCol_DockingEmptyBg, .{ 0.22, 0.22, 0.22, 1.00 });
}

fn set(style: *ig.ImGuiStyle, id: c_int, rgba: [4]f32) void {
    style.Colors[@intCast(id)] = .{ .x = rgba[0], .y = rgba[1], .z = rgba[2], .w = rgba[3] };
}
