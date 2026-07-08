const pie = @import("pie");
const std = @import("std");

const sokol = @import("sokol");
const sapp = sokol.app;

const Image = @import("./components/image.zig").Image;
const Darkroom = @import("./views/darkroom.zig").Darkroom;

const CurrentView = enum {
    darkroom,
};

// God Object for GUI State
pub const GUI = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // pie
    gpu: *pie.GPU,
    repo: *pie.modules.Repository,

    // view
    current_view: CurrentView = .darkroom,

    // views
    darkroom: Darkroom,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        gpu: *pie.GPU,
        repo: *pie.modules.Repository,
    ) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .gpu = gpu,
            .repo = repo,
            .current_view = .darkroom,
            .darkroom = .init(allocator, io, gpu, repo),
        };
    }

    pub fn deinit(self: *Self) void {
        self.darkroom.deinit();
    }

    pub fn update(self: *Self) void {
        switch (self.current_view) {
            .darkroom => {
                self.darkroom.update();
            },
        }
    }
    pub fn draw(self: *Self) void {
        switch (self.current_view) {
            .darkroom => {
                self.darkroom.draw();
            },
        }
    }
    pub fn event(self: *Self, ev: [*c]const sapp.Event) void {
        switch (self.current_view) {
            .darkroom => {
                self.darkroom.event(ev);
            },
        }
    }
};

pub fn gui_update(gui: *GUI) callconv(.c) void {
    gui.update();
}

pub fn gui_draw(gui: *GUI) callconv(.c) void {
    gui.draw();
}

comptime {
    @export(&gui_update, .{ .name = "gui_update" });
    @export(&gui_draw, .{ .name = "gui_draw" });
}
