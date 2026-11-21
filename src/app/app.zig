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
const ztracy = @import("ztracy");

const session = @import("session");
const Session = session.Session;
const GUI = @import("gui").GUI;

const util = @import("../mem.zig");

// God Object for app state.
//
// The app owns the window and sokol/ImGui contexts, the WebGPU device, the
// editing session (pipeline + textures + catalog + blit) and the GUI's view
// state.
pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// thumbnail cache directory (owned)
    cache_dir: []u8,
    /// print the pipeline performance report after every run (`--perf`)
    perf_report: bool = false,

    // sokol
    pass_action: sg.PassAction,

    // pie
    gpu: pie.gpu.GPU,

    // editing session (pipeline + blit resources + catalog)
    session: Session,
    // editor widgets
    gui: GUI,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io, cache_dir: []u8, perf_report: bool) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .cache_dir = cache_dir,
            .perf_report = perf_report,
            .pass_action = .{},
            // initted in the sokol callbacks below
            .gpu = undefined,
            .session = undefined,
            .gui = undefined,
        };
    }
};

export fn init_fn(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    ztracy.SetThreadName("main");
    ztracy.MessageC("pie init", 0x00_66_99_ff);

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

    // editing session (pipeline + blit resources + catalog) and the GUI
    state.session = Session.init(state.allocator, state.io, &state.gpu, state.cache_dir, state.perf_report) catch unreachable;
    state.gui = GUI.init(state.allocator, state.io) catch |err| {
        std.log.err("failed to init the GUI: {s}", .{@errorName(err)});
        unreachable;
    };
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    const tracy_frame = ztracy.ZoneNC(@src(), "frame", 0x00_33_33_33);
    defer tracy_frame.End();

    // Move catalog thumbnails along (uploads happen on this thread), then build
    // the graph once and re-run the editor pipeline if a parameter changed in
    // the previous frame. All of that submits GPU work, which is only legal
    // before the render pass starts.
    {
        const tracy_tick = ztracy.ZoneNC(@src(), "session.tick", 0x00_66_99_ff);
        defer tracy_tick.End();
        state.session.tick();
    }
    if (state.session.ensureBuilt()) {
        if (state.session.consumeRun()) {
            state.session.run() catch |err| {
                std.log.err("pipeline re-run failed: {s}", .{@errorName(err)});
                ztracy.MessageC("pipeline re-run failed", 0x00_00_00_ff);
            };
        }
    }

    // start the imgui frame (needs the framebuffer size + frame delta)
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    // the darkroom's image is drawn behind the widgets
    state.gui.drawImage(&state.session);
    state.gui.draw(&state.session);

    simgui.render();

    sg.endPass();
    sg.commit();

    ztracy.PlotF("frame_ms", sapp.frameDuration() * 1000.0);
    ztracy.FrameMark();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    state.gui.deinit();
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
        state.gui.event(&state.session, ev);
    }
}

pub fn run(init: std.process.Init) !void {
    // general purpose allocator for temporary heap allocations:
    const allocator = util.allocator;
    // default Io implementation:
    const io = init.io;

    var perf_report = false;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--perf")) {
            perf_report = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\usage: pie [--perf]
                \\  --perf  print the pipeline performance report after every run
                \\
            , .{});
            return;
        } else {
            std.log.warn("ignoring unknown argument '{s}' (try --help)", .{arg});
        }
    }

    // thumbnail cache lives under the user cache dir; keep it for the process
    const cache_dir = session.resolveCacheDir(allocator, init.environ_map) catch
        allocator.dupe(u8, ".pie-thumbs") catch unreachable;
    defer allocator.free(cache_dir);

    // Must outlive `sapp.run`: it is passed as user data to every callback.
    var state: AppState = AppState.init(allocator, io, cache_dir, perf_report);

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
