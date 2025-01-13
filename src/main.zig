const ig = @import("cimgui");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const std = @import("std");
const pretty = @import("pretty");
const util = @import("util.zig");

const ui = @import("ui.zig");

const AppState = struct {
    allocator: std.mem.Allocator,
    pass_action: sg.PassAction = .{},
    // windows: []const ui.IIgWindow, // https://github.com/ziglang/zig/issues/10529
    windows: ui.IIgWindow,

    fn init(self: *AppState, allocator: std.mem.Allocator) void {
        // const about: ui.About = undefined;
        // about.init();

        // const about = ui.About.create(allocator);
        const about = allocator.create(ui.About) catch unreachable;
        errdefer allocator.destroy(about);
        about.init(allocator);
        const windows = ui.IIgWindow.from(about);

        self.* = .{
            .allocator = allocator,
            .pass_action = .{},
            .windows = windows,
        };
    }

    fn deinit(self: *AppState) void {
        self.* = undefined;
    }

    /// Allocates and initializes
    pub fn create(allocator: std.mem.Allocator) *AppState {
        const result = allocator.create(AppState) catch unreachable;
        errdefer allocator.destroy(result);

        result.init(allocator);
        return result;
    }

    pub fn destroy(self: *AppState, allocator: std.mem.Allocator) void {
        // Free the resources
        self.windows.destroy(allocator);
        self.deinit();
        allocator.destroy(self);
    }
};
export fn init(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    // initialize sokol-imgui
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.5, .b = 1.0, .a = 1.0 },
    };
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    // call simgui.newFrame() before any ImGui calls
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    //=== UI CODE STARTS HERE
    // ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once);
    // ig.igSetNextWindowSize(.{ .x = 400, .y = 100 }, ig.ImGuiCond_Once);
    // _ = ig.igBegin("Hello Dear ImGui!", 0, ig.ImGuiWindowFlags_None);
    // _ = ig.igColorEdit3("Background", &state.pass_action.colors[0].clear_value.r, ig.ImGuiColorEditFlags_None);
    // ig.igEnd();

    // for (state.windows) |window| {
    //     window.render();
    // }
    state.windows.render();

    //=== UI CODE ENDS HERE

    // call simgui.render() inside a sokol-gfx pass
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    simgui.render();
    sg.endPass();
    sg.commit();
}

export fn cleanup(_: ?*anyopaque) void {
    // const state: *AppState = @ptrCast(@alignCast(ptr));
    simgui.shutdown();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, _: ?*anyopaque) void {
    // const state: *AppState = @ptrCast(@alignCast(ptr));
    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = AppState.create(allocator);
    defer state.destroy(allocator);

    // defer allocator.destroy(state);

    sapp.run(.{
        .user_data = @constCast(@ptrCast(@alignCast(state))),
        .init_userdata_cb = init,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .window_title = "sokol-zig + Dear Imgui",
        .width = 800,
        .height = 600,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
