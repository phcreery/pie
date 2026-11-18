//! The darkroom: a resizable split of the module panel and the image or node
//! graph.

const std = @import("std");
const cui = @import("cui");
const sg = @import("sokol").gfx;
const session = @import("session");
const Renderer = @import("cui_sokol").Renderer;
const ModulesPanel = @import("../components/modules_panel.zig").ModulesPanel;
const GraphView = @import("./graph.zig").GraphView;
const util = @import("../cui_util.zig");

pub const Mode = enum { image, graph };

const mode_items = [_][*c]const u8{ "Image", "Graph" };

pub const Darkroom = struct {
    mode: Mode = .image,
    split_ratio: f32 = 0.28,
    panel: ModulesPanel,
    graph: GraphView,
    image_view: cui.cui_image_view = .{},

    display_handle: cui.cui_texture = 0,
    display_view_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Darkroom {
        return .{
            .panel = try ModulesPanel.init(allocator),
            .graph = try GraphView.init(allocator),
        };
    }

    pub fn deinit(self: *Darkroom) void {
        self.panel.deinit();
        self.graph.deinit();
    }

    pub fn draw(self: *Darkroom, s: *session.Session, ui: *cui.cui_ctx, renderer: *Renderer) void {
        self.drawToolbar(ui);

        var split = util.zero(cui.cui_split_opts);
        split.vertical = false;
        split.min_first = 190;
        split.min_second = 260;
        split.width = util.fill();
        split.height = util.fill();
        cui.cui_split_begin(ui, "darkroom-split", &self.split_ratio, &split);
        defer cui.cui_split_end(ui);

        self.panel.draw(s, ui);
        cui.cui_split_next(ui);
        switch (self.mode) {
            .image => self.drawImage(s, ui, renderer),
            .graph => self.graph.draw(s, ui),
        }
    }

    fn drawToolbar(self: *Darkroom, ui: *cui.cui_ctx) void {
        var row = util.zero(cui.cui_box);
        row.dir = @intCast(cui.CUI_ROW);
        row.width = util.fill();
        row.height = util.fit();
        row.pad = 4;
        row.gap = 6;
        row.@"align" = @intCast(cui.CUI_ALIGN_CENTER);
        _ = cui.cui_row_begin(ui, &row);
        defer cui.cui_box_end(ui);

        var items = [_][*c]const u8{ "Image", "Graph" };
        var index: c_int = @backingInt(self.mode);
        var seg = util.zero(cui.cui_segmented_opts);
        if (cui.cui_segmented_ex(ui, "darkroom-mode", &items, 2, &index, &seg)) {
            self.mode = @fromBackingInt(@intCast(index));
        }

        cui.cui_spacer(ui);

        switch (self.mode) {
            .image => cui.cui_muted(ui, "wheel zooms, drag pans"),
            .graph => cui.cui_muted(ui, "drag a pin to connect, F frames, Delete removes"),
        }
    }

    fn drawImage(self: *Darkroom, s: *session.Session, ui: *cui.cui_ctx, renderer: *Renderer) void {
        const handle = self.displayTexture(s, renderer);
        if (handle == 0) {
            var box = util.zero(cui.cui_box);
            box.dir = @intCast(cui.CUI_COLUMN);
            box.width = util.fill();
            box.height = util.fill();
            box.@"align" = @intCast(cui.CUI_ALIGN_CENTER);
            box.justify = @intCast(cui.CUI_JUSTIFY_CENTER);
            box.bg = util.token(ui, cui.CUI_TOKEN_BACKGROUND);
            _ = cui.cui_column_begin(ui, &box);
            cui.cui_muted(ui, "No image loaded");
            cui.cui_box_end(ui);
            return;
        }

        var opts = util.zero(cui.cui_image_viewer_opts);
        opts.width = util.fill();
        opts.height = util.fill();
        _ = cui.cui_image_viewer_ex(
            ui,
            "darkroom-image",
            handle,
            @intFromFloat(s.display.width),
            @intFromFloat(s.display.height),
            &self.image_view,
            &opts,
        );
    }

    fn displayTexture(self: *Darkroom, s: *session.Session, renderer: *Renderer) cui.cui_texture {
        const view = s.display.view;
        if (view.id != self.display_view_id) {
            if (self.display_handle != 0) renderer.releaseView(self.display_handle);
            self.display_handle = 0;
            self.display_view_id = view.id;
            if (view.id != sg.invalid_id) {
                self.display_handle = renderer.registerView(
                    view,
                    @intFromFloat(s.display.width),
                    @intFromFloat(s.display.height),
                ) catch 0;
            }
        }
        return self.display_handle;
    }
};
