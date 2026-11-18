//! The editor's menu bar, built from CUI's app-chrome components.

const std = @import("std");
const cui = @import("cui");
const sapp = @import("sokol").app;
const session = @import("session");
const root = @import("../root.zig");
const GUI = root.GUI;
const util = @import("../cui_util.zig");

pub const MenuBar = struct {
    pub fn draw(gui: *GUI, s: *session.Session, ui: *cui.cui_ctx) void {
        var bar_opts = util.zero(cui.cui_menu_bar_opts);
        cui.cui_menu_bar_begin(ui, "main-menu", &bar_opts);
        defer cui.cui_menu_bar_end(ui);

        var menu_opts = util.zero(cui.cui_menu_bar_menu_opts);
        if (cui.cui_menu_bar_menu_begin(ui, "File", &menu_opts)) {
            defer cui.cui_menu_bar_menu_end(ui);
            var item = util.zero(cui.cui_menu_item_opts);
            if (cui.cui_menu_item_ex(ui, "Reload catalog", &item)) s.reloadCatalog();
            cui.cui_menu_separator(ui);
            if (cui.cui_menu_item_ex(ui, "Quit", &item)) sapp.requestQuit();
        }

        if (cui.cui_menu_bar_menu_begin(ui, "View", &menu_opts)) {
            defer cui.cui_menu_bar_menu_end(ui);
            var item = util.zero(cui.cui_menu_item_opts);
            item.checked = gui.view == .darkroom;
            if (cui.cui_menu_item_ex(ui, "Darkroom", &item)) gui.view = .darkroom;
            item.checked = gui.view == .lighttable;
            if (cui.cui_menu_item_ex(ui, "Lighttable", &item)) gui.view = .lighttable;
        }
    }
};
