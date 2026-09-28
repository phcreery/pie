//! The editor's main menu bar.

const std = @import("std");
const ig = @import("cimgui");
const sapp = @import("sokol").app;
const session = @import("session");
const root = @import("../root.zig");
const GUI = root.GUI;

pub const MenuBar = struct {
    pub fn draw(gui: *GUI, s: *session.Session) void {
        if (!ig.igBeginMainMenuBar()) return;
        defer ig.igEndMainMenuBar();

        // Switch between darkroom and lighttable views
        var label_buf: [32]u8 = undefined;
        const label = std.mem.printSentinel(&label_buf, "{s}##view", .{viewName(gui.view)}, 0) catch "##view";
        if (ig.igButton(label.ptr)) gui.view = switchView(gui.view);

        if (ig.igBeginMenu("File")) {
            if (ig.igMenuItemEx("Reload catalog", "", false, true)) {
                s.reloadCatalog();
            }
            ig.igSeparator();
            if (ig.igMenuItemEx("Quit", "", false, true)) {
                sapp.requestQuit();
            }
            ig.igEndMenu();
        }
    }

    fn switchView(view: root.ViewKind) root.ViewKind {
        return if (view == .darkroom) .lighttable else .darkroom;
    }

    fn viewName(view: root.ViewKind) []const u8 {
        return switch (view) {
            .darkroom => "Darkroom",
            .lighttable => "Lighttable",
        };
    }
};
