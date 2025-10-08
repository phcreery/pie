const ig = @import("cimgui");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const std = @import("std");
const pretty = @import("pretty");
const util = @import("../util.zig");
const builtin = @import("builtin");

const window = @import("window.zig");

const AppState = struct {
    pass_action: sg.PassAction = .{},
    // windows: *ui.WindowManager,
    window: window.IIgWindow,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) AppState {
        // std.debug.print("AppState.init windows\n", .{});
        // pretty.print(util.gpa, windows, .{}) catch unreachable;

        const about = allocator.create(window.About) catch unreachable;
        // const about = window.About.init(allocator);
        errdefer allocator.destroy(about);
        about.* = window.About.init(allocator);

        std.debug.print("WindowManager.init about\n", .{});
        // pretty.print(util.allocator, about, .{}) catch unreachable;

        const about_window = window.IIgWindow.from(about);
        // const window = allocator.create(ui.IIgWindow) catch unreachable;
        // window.* = ui.IIgWindow.from(about);
        std.debug.print("WindowManager.init window\n", .{});
        // pretty.print(util.allocator, about_window, .{}) catch unreachable;

        return .{
            .pass_action = .{},
            // .windows = windows,
            .window = about_window,
        };
    }

    fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        // Free the resources
        self.window.deinit(allocator);
        self.deinit();
        allocator.destroy(self);
    }
};

// export fn init() void {
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

// export fn frame() void {
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
    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once);
    ig.igSetNextWindowSize(.{ .x = 400, .y = 100 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("Hello Dear ImGui!", 0, ig.ImGuiWindowFlags_None);
    _ = ig.igColorEdit3("Background", &state.pass_action.colors[0].clear_value.r, ig.ImGuiColorEditFlags_None);
    ig.igEnd();

    std.debug.print("frame state\n", .{});
    // std.debug.print("{}\n", .{state});
    pretty.print(util.allocator, state, .{}) catch unreachable;

    // state.windows.render();
    state.window.render();

    //=== UI CODE ENDS HERE

    // call simgui.render() inside a sokol-gfx pass
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    simgui.render();
    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    _ = state;
    simgui.shutdown();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    _ = state;
    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);
}

pub fn run() void {
    // Allocate the application state on the heap to ensure it lives long enough.
    // const state = util.allocator.create(AppState) catch unreachable;
    // errdefer util.allocator.destroy(state);
    // state.* = AppState.init(util.allocator);

    // Alternatively, allocate the application state on the stack
    const state: *AppState = @constCast(&AppState.init(util.allocator));
    defer state.deinit();

    sapp.run(.{
        .user_data = state,
        .init_userdata_cb = init,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .window_title = "PIE",
        .width = 800,
        .height = 600,
        .logger = .{ .func = slog.func },
    });
}
