//! The lighttable view: a scrollable grid of catalog thumbnails.
//!
//! A pure function of the host-built `abi.LighttableModel` and the host-owned
//! `LighttableState`: thumbnails are textures the host created (`ImageRef`),
//! selection is written straight into the shared state (like the darkroom's
//! zoom/pan), and opening an image is an intent. No engine code, no I/O, no
//! decoding — the host does that.

const std = @import("std");
const ig = @import("cimgui");
const abi = @import("abi");

pub const Lighttable = struct {
    /// thumbnail square, cell = thumb + label strip
    const thumb_px: f32 = 128;
    const cell_w: f32 = 148;
    const cell_h: f32 = 136;
    const pad: f32 = 4;

    /// ABGR (imgui's packing)
    const color_placeholder: u32 = 0x40_FF_FF_FF;
    const color_failed: u32 = 0x60_40_40_C0;
    const color_label: u32 = 0xFF_E0_E0_E0;
    const color_label_dim: u32 = 0xFF_90_90_90;

    pub fn draw(state: *abi.SharedState, model: *const abi.LighttableModel) void {
        const viewport = ig.igGetMainViewport();
        ig.igSetNextWindowPos(viewport.*.WorkPos, ig.ImGuiCond_Always);
        ig.igSetNextWindowSize(viewport.*.WorkSize, ig.ImGuiCond_Always);

        const flags = ig.ImGuiWindowFlags_NoTitleBar |
            ig.ImGuiWindowFlags_NoResize |
            ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoBringToFrontOnFocus |
            ig.ImGuiWindowFlags_NoSavedSettings;
        if (!ig.igBegin("lighttable", null, flags)) {
            ig.igEnd();
            return;
        }
        defer ig.igEnd();

        drawStatus(state, model);
        ig.igSeparator();

        var avail = ig.igGetContentRegionAvail();
        if (avail.x < cell_w) avail.x = cell_w;
        if (avail.y < cell_h) avail.y = cell_h;
        if (ig.igBeginChild("grid", avail, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_NoSavedSettings)) {
            drawGrid(state, model, avail.x);
        }
        ig.igEndChild();

        // Enter opens the selection; double click is the mouse equivalent
        if (ig.igIsKeyPressed(ig.ImGuiKey_Enter) or ig.igIsKeyPressed(ig.ImGuiKey_KeypadEnter)) {
            if (state.lighttable.selected < model.items.len) {
                _ = state.push(.{ .open_image = state.lighttable.selected });
            }
        }
    }

    fn drawStatus(state: *abi.SharedState, model: *const abi.LighttableModel) void {
        var pending: usize = 0;
        for (model.items) |item| {
            if (item.thumb == null and !item.failed) pending += 1;
        }

        var buf: [512]u8 = undefined;
        const selected = if (state.lighttable.selected < model.items.len)
            model.items[state.lighttable.selected].name
        else
            "";
        const line = std.mem.printSentinel(&buf, "{s}   {d} images, {d} decoding   selected: {s}", .{
            model.dir, model.items.len, pending, selected,
        }, 0) catch return;
        ig.igText("%s", line.ptr);
    }

    fn drawGrid(state: *abi.SharedState, model: *const abi.LighttableModel, avail_w: f32) void {
        const columns = @max(1, @as(usize, @intFromFloat(@floor((avail_w + pad) / (cell_w + pad)))));
        const rows = (model.items.len + columns - 1) / columns;

        const draw_list = ig.igGetWindowDrawList();
        const origin = ig.igGetCursorScreenPos();
        const text_h = ig.igGetTextLineHeight();

        // reserve the whole grid so the child window scrolls over all of it
        if (rows > 0) {
            ig.igDummy(.{
                .x = @as(f32, @floatFromInt(columns)) * (cell_w + pad),
                .y = @as(f32, @floatFromInt(rows)) * (cell_h + pad),
            });
        }

        for (model.items, 0..) |item, index| {
            const column = index % columns;
            const row = index / columns;
            const x = origin.x + @as(f32, @floatFromInt(column)) * (cell_w + pad);
            const y = origin.y + @as(f32, @floatFromInt(row)) * (cell_h + pad);

            const min = ig.ImVec2{ .x = x, .y = y };
            const max = ig.ImVec2{ .x = x + cell_w, .y = y + cell_h };
            const thumb_min = ig.ImVec2{ .x = x + pad, .y = y + pad };
            const thumb_max = ig.ImVec2{ .x = x + pad + thumb_px, .y = y + pad + thumb_px };

            const selected = state.lighttable.selected == @as(u32, @intCast(index));
            const bg = if (selected)
                ig.igGetColorU32Ex(ig.ImGuiCol_HeaderActive, 1)
            else
                ig.igGetColorU32Ex(ig.ImGuiCol_FrameBg, 0.6);
            ig.ImDrawList_AddRectFilled(draw_list, min, max, bg);

            if (item.thumb) |thumb| {
                // letterbox the host's texture inside the square
                if (thumb.width > 0 and thumb.height > 0) {
                    const scale = @min(thumb_px / thumb.width, thumb_px / thumb.height);
                    const w = thumb.width * scale;
                    const h = thumb.height * scale;
                    const img_min = ig.ImVec2{
                        .x = thumb_min.x + (thumb_px - w) * 0.5,
                        .y = thumb_min.y + (thumb_px - h) * 0.5,
                    };
                    const img_max = ig.ImVec2{ .x = img_min.x + w, .y = img_min.y + h };
                    const tex_ref = ig.ImTextureRef{ ._TexData = null, ._TexID = thumb.id };
                    ig.ImDrawList_AddImage(draw_list, tex_ref, img_min, img_max);
                }
            } else {
                const color: u32 = if (item.failed) color_failed else color_placeholder;
                ig.ImDrawList_AddRectFilled(draw_list, thumb_min, thumb_max, color);

                var msg_buf: [32]u8 = undefined;
                const msg = std.mem.printSentinel(&msg_buf, "{s}", .{if (item.failed) "failed" else "decoding..."}, 0) catch "";
                ig.ImDrawList_AddText(draw_list, .{
                    .x = thumb_min.x + 8,
                    .y = thumb_min.y + thumb_px * 0.5 - text_h * 0.5,
                }, color_label, msg.ptr);
            }

            // label: file name, first line's worth of it
            var name_buf: [64]u8 = undefined;
            const name = truncateZ(&name_buf, item.name);
            ig.ImDrawList_AddText(draw_list, .{
                .x = thumb_min.x + 2,
                .y = thumb_max.y + 4,
            }, if (selected) color_label else color_label_dim, name.ptr);

            // one click target per cell, placed at an absolute position so the
            // grid does not depend on imgui's cursor flow
            var id_buf: [32]u8 = undefined;
            const id = std.mem.printSentinel(&id_buf, "cell##{d}", .{index}, 0) catch continue;
            ig.igSetCursorScreenPos(min);
            if (ig.igInvisibleButton(id.ptr, .{ .x = cell_w, .y = cell_h }, ig.ImGuiButtonFlags_None)) {
                state.lighttable.selected = @intCast(index);
            }
            if (ig.igIsItemHovered(ig.ImGuiHoveredFlags_None) and ig.igIsMouseDoubleClicked(ig.ImGuiMouseButton_Left)) {
                state.lighttable.selected = @intCast(index);
                _ = state.push(.{ .open_image = @intCast(index) });
            }
        }
    }

    /// Copy `name` into `buf` as a NUL-terminated string, dropping the tail.
    fn truncateZ(buf: []u8, name: []const u8) [:0]const u8 {
        const len = @min(name.len, buf.len - 1);
        @memcpy(buf[0..len], name[0..len]);
        buf[len] = 0;
        return buf[0..len :0];
    }
};
