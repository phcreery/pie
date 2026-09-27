//! The editor's main menu bar.

const std = @import("std");
const ig = @import("cimgui");
const sapp = @import("sokol").app;
const session = @import("session");
const GUI = @import("../root.zig").GUI;

pub const MenuBar = struct {
    pub fn draw(gui: *GUI, s: *session.Session) void {
        if (!ig.igBeginMainMenuBar()) return;
        defer ig.igEndMainMenuBar();

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

        if (ig.igBeginMenu("View")) {
            if (ig.igMenuItemEx("Darkroom", "", gui.view == .darkroom, true)) {
                gui.view = .darkroom;
            }
            if (ig.igMenuItemEx("Lighttable", "", gui.view == .lighttable, true)) {
                gui.view = .lighttable;
            }
            ig.igEndMenu();
        }

        var buf: [96]u8 = undefined;
        const status = std.mem.printSentinel(&buf, "{s}  |  {d} images", .{ @tagName(gui.view), s.catalog.entries.len }, 0) catch "";
        ig.igText("%s", status.ptr);
    }
};
