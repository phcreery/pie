//! GUI root — the editor's widget tree, compiled into the app.
//!
//! The GUI owns no engine state: it reads the live editing session (`pipeline`,
//! `catalog`, `blit`) directly and mutates only its own view state. Views are
//! stateless functions over a borrowed `*session.Session`.

const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const session = @import("session");
const Darkroom = @import("./views/darkroom.zig").Darkroom;
const Lighttable = @import("./views/lighttable.zig").Lighttable;
const MenuBar = @import("./components/menu_bar.zig").MenuBar;
const theme = @import("./theme.zig");

pub const ViewKind = enum { darkroom, lighttable };

pub const GUI = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    view: ViewKind = .lighttable,
    darkroom: Darkroom = .{},
    lighttable: Lighttable = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !GUI {
        theme.apply();
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *GUI) void {
        _ = self;
    }

    /// The image quad is drawn behind the widgets, before the rest of the GUI.
    /// The darkroom lays its split out first so the blit and the widgets agree
    /// on where the image region is.
    pub fn drawImage(self: *GUI, s: *session.Session) void {
        if (self.view != .darkroom) return;
        self.darkroom.layout();
        s.blit.draw(self.darkroom.zoom, self.darkroom.pan, self.darkroom.image_rect);
    }

    /// Draw the menu bar and the active view's widgets. The menu bar is drawn
    /// first so imgui offsets the viewport's work area for it.
    pub fn draw(self: *GUI, s: *session.Session) void {
        MenuBar.draw(self, s);
        switch (self.view) {
            .darkroom => self.darkroom.draw(s),
            .lighttable => self.lighttable.draw(self, s),
        }
    }

    /// Mouse/keyboard input that ImGui did not consume. Both views are imgui
    /// widgets, so only the image view needs raw input (pan/zoom).
    pub fn event(self: *GUI, s: *session.Session, ev: [*c]const sapp.Event) void {
        _ = s;
        switch (self.view) {
            .darkroom => self.darkroom.event(ev),
            .lighttable => {},
        }
    }
};
