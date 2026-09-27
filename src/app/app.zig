const std = @import("std");

const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;

const pie = @import("pie");
const console = @import("console");
const wgpu = @import("wgpu_zig");

const abi = @import("abi");
const GuiPlugin = @import("plugin.zig").GuiPlugin;
const Session = @import("session.zig").Session;

const util = @import("../mem.zig");

// God Object for app state.
//
// The host owns everything that must survive a GUI reload: the window and
// sokol/ImGui contexts, the WebGPU device, the editing session (pipeline +
// textures) and the state/model the plugin reads and writes. The plugin itself
// is stateless code, swapped in place by `GuiPlugin`.
pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // sokol
    pass_action: sg.PassAction,

    // pie
    gpu: pie.gpu.GPU,

    // hot-reloadable GUI
    session: Session,
    /// host-owned, mutated in place by the plugin
    gui_state: abi.SharedState,
    /// what the plugin draws, built once the pipeline exists
    gui_model: abi.Model,
    gui_plugin: GuiPlugin,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .pass_action = .{},
            // initted in the sokol callbacks below
            .gpu = undefined,
            .session = undefined,
            .gui_state = .{},
            .gui_model = .{},
            .gui_plugin = undefined,
        };
    }
};

export fn init_fn(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // initialize sokol-imgui
    simgui.setup(.{
        .ini_filename = null,
        .logger = .{ .func = slog.func },
    });

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        // 18% Reflective Gray
        .clear_value = .{ .r = 0.462, .g = 0.462, .b = 0.462, .a = 1.0 },
    };

    // initialize pie pipeline
    const ext_device = wgpu.Device{ .device = @ptrCast(@constCast(sg.wgpuDevice().?)) };
    const ext_queue = wgpu.Queue{ .queue = @ptrCast(@constCast(sg.wgpuQueue().?)) };
    state.gpu = pie.GPU.initExternal(state.allocator, state.io, ext_device, ext_queue) catch unreachable;

    // editing session (pipeline + blit resources) and the GUI plugin
    state.session = Session.init(state.allocator, state.io, &state.gpu) catch unreachable;
    state.gui_plugin = GuiPlugin.init(state.allocator, state.io, &state.gui_state) catch |err| {
        std.log.err("failed to load the GUI plugin: {s}", .{@errorName(err)});
        std.log.err("build it with: zig build gui", .{});
        unreachable;
    };
    std.log.info("GUI plugin generation {d} loaded from {s}", .{ state.gui_plugin.generation, state.gui_plugin.path });
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // Hot reload first: swapping the plugin code must not happen inside a
    // render pass or an open ImGui frame.
    state.gui_plugin.tick();
    state.gui_state.frame += 1;

    // Move catalog thumbnails along (uploads happen on this thread), then build
    // the graph once and apply whatever the plugin asked for in the previous
    // frame. All of that submits GPU work, which is only legal before the
    // render pass starts.
    state.session.tick();
    if (state.session.ensureBuilt()) state.session.refreshModel(&state.gui_model);
    if (state.session.applyIntents(&state.gui_state)) {
        state.session.run() catch |err| {
            std.log.err("pipeline re-run failed: {s}", .{@errorName(err)});
        };
    }

    // start the imgui frame (needs the framebuffer size + frame delta)
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    // the darkroom's image is host-drawn behind the widgets; the lighttable
    // draws its own thumbnails from inside the plugin
    if (state.gui_state.view == .darkroom) {
        state.session.blit.draw(state.gui_state.darkroom.zoom, state.gui_state.darkroom.pan);
    }
    state.gui_plugin.draw(&state.gui_state, &state.gui_model);

    simgui.render();

    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    state.gui_plugin.deinit();
    state.session.deinit();
    state.gpu.deinit();
    simgui.shutdown();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    // sokol-imgui returns true when it wants mouse/keyboard input (e.g. the
    // cursor is over an imgui window or a widget is being dragged). When that
    // happens don't forward the event to the GUI so the image pan/zoom and
    // other app-level input handlers don't fight the imgui widgets.
    const imgui_consumed = simgui.handleEvent(ev.*);
    if (!imgui_consumed) {
        state.gui_plugin.event(&state.gui_state, ev);
    }
}

pub fn run(init: std.process.Init) !void {
    // general purpose allocator for temporary heap allocations:
    const allocator = util.allocator;
    // default Io implementation:
    const io = init.io;

    // Must outlive `sapp.run`: it is passed as user data to every callback.
    var state: AppState = AppState.init(allocator, io);

    const cout = console.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    sapp.run(.{
        .user_data = &state,
        .init_userdata_cb = init_fn,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .window_title = "PIE",
        .width = 800,
        .height = 600,
        .logger = .{ .func = slog.func },
    });
}
