//! The lighttable: a scrollable grid of catalog thumbnails, now a CUI grid.

const std = @import("std");
const cui = @import("cui");
const sg = @import("sokol").gfx;
const session = @import("session");
const Renderer = @import("cui_sokol").Renderer;
const GUI = @import("../root.zig").GUI;
const util = @import("../cui_util.zig");

/// Copied into CUI's frame arena by `cui_canvas`; the paint callback runs later.
const ThumbPaint = extern struct {
    tex: cui.cui_texture,
    w: f32,
    h: f32,
};

fn paintThumb(ui_ptr: ?*cui.cui_ctx, r: cui.cui_rect, user: ?*anyopaque) callconv(.c) void {
    const ui = ui_ptr orelse return;
    const data: *const ThumbPaint = @ptrCast(@alignCast(user orelse return));
    if (data.tex == 0 or data.w <= 0 or data.h <= 0) return;

    // Letterbox: fit inside the canvas rect, keep the thumbnail's aspect.
    var dw = r.w;
    var dh = r.w * data.h / data.w;
    if (dh > r.h) {
        dh = r.h;
        dw = r.h * data.w / data.h;
    }
    const x = r.x + (r.w - dw) * 0.5;
    const y = r.y + (r.h - dh) * 0.5;

    cui.cui_draw_image(
        ui,
        data.tex,
        .{ .x = x, .y = y, .w = dw, .h = dh },
        .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        util.zero(cui.cui_corners),
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
}

pub const Lighttable = struct {
    const Slot = struct {
        handle: cui.cui_texture = 0,
        view_id: u32 = 0,
    };

    allocator: std.mem.Allocator,
    selected: u32 = 0,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    strings: util.FrameStrings,

    pub fn init(allocator: std.mem.Allocator) !Lighttable {
        return .{
            .allocator = allocator,
            .strings = util.FrameStrings.init(allocator),
        };
    }

    pub fn deinit(self: *Lighttable) void {
        self.slots.deinit(self.allocator);
        self.strings.deinit();
    }

    pub fn draw(self: *Lighttable, gui: *GUI, s: *session.Session, ui: *cui.cui_ctx, renderer: *Renderer) void {
        self.strings.reset();
        var page = util.zero(cui.cui_box);
        page.dir = @intCast(cui.CUI_COLUMN);
        page.width = util.fill();
        page.height = util.fill();
        page.pad = 8;
        page.gap = 8;
        page.bg = util.token(ui, cui.CUI_TOKEN_BACKGROUND);
        _ = cui.cui_column_begin(ui, &page);
        defer cui.cui_box_end(ui);

        const dir = self.strings.alloc(s.catalog.dir) catch return;
        var button = util.zero(cui.cui_button_opts);
        button.full_width = true;
        if (cui.cui_button_ex(ui, dir.ptr, &button)) {
            s.browseCatalog();
        }

        const count = s.catalog.entries.len;
        if (count == 0) {
            cui.cui_muted(ui, "No images in this folder");
            return;
        }
        if (self.selected >= count) self.selected = @intCast(count - 1);
        self.syncSlots(s, renderer);

        var grid = util.zero(cui.cui_box);
        grid.dir = @intCast(cui.CUI_GRID);
        grid.id = "lighttable-grid";
        grid.min_column_width = 156;
        grid.width = util.fill();
        grid.height = util.fill();
        grid.gap = 8;
        grid.scroll_y = true;
        grid.clip = true;
        _ = cui.cui_box_begin(ui, &grid);
        defer cui.cui_box_end(ui);

        for (s.catalog.entries, 0..) |entry, index| {
            const selected = self.selected == @as(u32, @intCast(index));
            var card = util.zero(cui.cui_card_opts);
            const card_id = self.strings.fmt("thumb-{d}", .{index}) catch return;
            card.id = card_id.ptr;
            card.hoverable = true;
            card.selected = selected;
            card.pad = 4;
            card.gap = 2;
            card.width = util.fill();
            var clicked = cui.cui_card_begin(ui, &card);
            defer cui.cui_card_end(ui);

            const state = s.catalog.entryState(index);
            const handle = self.slots.items[index].handle;
            if (state.ready and handle != 0) {
                const size = s.catalog.thumbSize(index);
                var paint_data = ThumbPaint{
                    .tex = handle,
                    .w = @floatFromInt(size[0]),
                    .h = @floatFromInt(size[1]),
                };
                const canvas_id = self.strings.fmt("thumb-img-{d}", .{index}) catch return;
                const canvas = cui.cui_canvas(
                    ui,
                    canvas_id.ptr,
                    util.fill(),
                    util.px(120),
                    paintThumb,
                    &paint_data,
                    @sizeOf(ThumbPaint),
                );
                clicked = clicked or canvas.clicked;
            } else {
                var placeholder = util.zero(cui.cui_box);
                placeholder.dir = @intCast(cui.CUI_COLUMN);
                placeholder.width = util.fill();
                placeholder.height = util.px(120);
                placeholder.bg = util.token(ui, cui.CUI_TOKEN_SURFACE_MUTED);
                placeholder.@"align" = @intCast(cui.CUI_ALIGN_CENTER);
                placeholder.justify = @intCast(cui.CUI_JUSTIFY_CENTER);
                _ = cui.cui_box_begin(ui, &placeholder);
                cui.cui_muted(ui, if (state.failed) "failed" else "decoding...");
                cui.cui_box_end(ui);
            }

            const name = self.strings.alloc(entry.name) catch return;
            var text = util.zero(cui.cui_text_opts);
            text.nowrap = true;
            cui.cui_text_ex(ui, name.ptr, &text);

            if (clicked) {
                if (selected) {
                    s.openImage(@intCast(index));
                    gui.view = .darkroom;
                } else {
                    self.selected = @intCast(index);
                }
            }
        }

        if (!cui.cui_wants_keyboard(ui) and cui.cui_key_pressed(ui, @intCast(cui.CUI_KEY_ENTER))) {
            if (self.selected < s.catalog.entries.len) {
                s.openImage(self.selected);
                gui.view = .darkroom;
            }
        }
    }

    fn syncSlots(self: *Lighttable, s: *session.Session, renderer: *Renderer) void {
        const count = s.catalog.entries.len;
        while (self.slots.items.len > count) {
            const slot = self.slots.pop().?;
            if (slot.handle != 0) renderer.releaseView(slot.handle);
        }
        while (self.slots.items.len < count) {
            self.slots.append(self.allocator, .{}) catch return;
        }

        for (s.catalog.entries, 0..) |_, index| {
            const view = s.catalog.viewOf(index);
            const slot = &self.slots.items[index];
            if (slot.view_id == view.id) continue;
            if (slot.handle != 0) renderer.releaseView(slot.handle);
            slot.* = .{ .view_id = view.id };
            if (view.id == sg.invalid_id) continue;
            const size = s.catalog.thumbSize(index);
            slot.handle = renderer.registerView(view, size[0], size[1]) catch 0;
        }
    }
};
