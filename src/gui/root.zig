//! GUI root — the editor's CUI widget tree.
//!
//! The GUI owns no engine state: it reads the live session (`pipeline`,
//! `catalog`, `display`) and mutates only its own view state.

const std = @import("std");
const cui = @import("cui");
const Renderer = @import("cui_sokol").Renderer;
const session = @import("session");
const Darkroom = @import("./views/darkroom.zig").Darkroom;
const Lighttable = @import("./views/lighttable.zig").Lighttable;
const MenuBar = @import("./components/menu_bar.zig").MenuBar;
const util = @import("./cui_util.zig");

pub const theme = @import("./theme.zig");

pub const ViewKind = enum { darkroom, lighttable };

pub const GUI = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    view: ViewKind = .lighttable,
    darkroom: Darkroom,
    lighttable: Lighttable,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !GUI {
        return .{
            .allocator = allocator,
            .io = io,
            .darkroom = try Darkroom.init(allocator),
            .lighttable = try Lighttable.init(allocator),
        };
    }

    pub fn deinit(self: *GUI) void {
        self.darkroom.deinit();
        self.lighttable.deinit();
    }

    /// Draw the menu bar and the active view.
    pub fn draw(self: *GUI, s: *session.Session, ui: *cui.cui_ctx, renderer: *Renderer) void {
        var root = util.zero(cui.cui_box);
        root.dir = @intCast(cui.CUI_COLUMN);
        root.width = util.fill();
        root.height = util.fill();
        root.pad = 0;
        root.gap = 0;
        _ = cui.cui_column_begin(ui, &root);
        defer cui.cui_box_end(ui);

        MenuBar.draw(self, s, ui);
        switch (self.view) {
            .darkroom => self.darkroom.draw(s, ui, renderer),
            .lighttable => self.lighttable.draw(self, s, ui, renderer),
        }
    }
};
