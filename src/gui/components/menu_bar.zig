//! The editor's main menu bar.
//!
//! The menu structure is pure UI (the part you iterate on with hot reload);
//! everything it triggers is an intent the host applies.

const std = @import("std");
const ig = @import("cimgui");
const abi = @import("abi");

pub const MenuBar = struct {
    pub fn draw(state: *abi.SharedState) void {
        if (!ig.igBeginMainMenuBar()) return;
        defer ig.igEndMainMenuBar();

        if (ig.igBeginMenu("File")) {
            if (ig.igMenuItemEx("Reload catalog", "", false, true)) {
                _ = state.push(.reload_catalog);
            }
            ig.igSeparator();
            if (ig.igMenuItemEx("Quit", "", false, true)) {
                _ = state.push(.quit);
            }
            ig.igEndMenu();
        }

        if (ig.igBeginMenu("View")) {
            if (ig.igMenuItemEx("Darkroom", "", state.view == .darkroom, true)) {
                _ = state.push(.{ .switch_view = .darkroom });
            }
            if (ig.igMenuItemEx("Lighttable", "", state.view == .lighttable, true)) {
                _ = state.push(.{ .switch_view = .lighttable });
            }
            ig.igEndMenu();
        }

        var buf: [96]u8 = undefined;
        const status = std.mem.printSentinel(&buf, "{s}  |  plugin reloads {d}", .{ @tagName(state.view), state.reloads }, 0) catch "";
        ig.igText("%s", status.ptr);
    }
};
