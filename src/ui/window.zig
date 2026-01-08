const std = @import("std");
const use_docking = @import("build_options").docking;
const ig = if (use_docking) @import("cimgui_docking") else @import("cimgui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const pretty = @import("pretty");
const util = @import("../mem.zig");
const builtin = @import("builtin");

const build = @import("build_options");
const zdt = @import("zdt");
const Datetime = zdt.Datetime;
const libraw = @import("libraw");

pub const WindowManager = struct {
    windows: std.ArrayList(IIgWindow),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var windows = std.ArrayList(IIgWindow).initCapacity(allocator, 20) catch unreachable;

        const about = &About.init(allocator);
        const window = IIgWindow.from(about);
        windows.append(window) catch unreachable;

        return .{
            // .allocator = allocator,
            .windows = windows,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.windows.items) |window| {
            window.destroy(self.allocator);
        }
        self.windows.deinit();
        allocator.destroy(self);
    }

    pub fn render(self: *Self) void {
        std.debug.print("WindowManager.render self\n", .{});
        // pretty.print(util.allocator, self, .{}) catch unreachable;

        const open = &true;
        ig.igShowMetricsWindow(@ptrCast(@constCast(open)));
        for (self.windows.items) |window| {
            window.render();
        }
    }

    pub fn add(self: *Self, window: IIgWindow) void {
        self.windows.append(window) catch unreachable;
    }
};

// https://www.openmymind.net/Zig-Interfaces/
// https://medium.com/@jerrythomas_in/exploring-compile-time-interfaces-in-zig-5c1a1a9e59fd
/// IIgWindow is an interface for rendering an ImGui window.
/// It is recommended to use a heap allocated struct as the context.
pub const IIgWindow = struct {
    ptr: *anyopaque,
    impl: Interface,

    pub const Interface = struct {
        renderFn: *const fn (ptr: *anyopaque) void,
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn render(self: IIgWindow) void {
        // std.debug.print("IIgWindow.render self\n", .{});
        // pretty.print(util.allocator, self, .{}) catch unreachable;
        return self.impl.renderFn(self.ptr);
    }

    pub fn deinit(self: IIgWindow, allocator: std.mem.Allocator) void {
        return self.impl.deinitFn(self.ptr, allocator);
    }

    // This is new
    pub fn from(ptr: anytype) IIgWindow {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        if (ptr_info != .pointer) @compileError("ptr must be a pointer");
        if (ptr_info.pointer.size != .one) @compileError("ptr must be a single item pointer");

        const gen = struct {
            pub fn render(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                std.debug.print("IIgWindow.from.render self\n", .{});
                // pretty.print(util.allocator, self, .{}) catch unreachable;

                return ptr_info.pointer.child.render(self);
            }
            pub fn deinit(pointer: *anyopaque, allocator: std.mem.Allocator) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.deinit(self, allocator);
            }
        };

        return .{
            .ptr = ptr,
            .impl = .{ .renderFn = gen.render, .deinitFn = gen.deinit },
        };
    }
};

pub const About = struct {
    allocator: std.mem.Allocator,
    is_open: bool,
    init_pos: ig.ImVec2,
    init_size: ig.ImVec2,
    cimgui_version: []const u8,
    libraw_version: []const u8,
    build_date: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        // https://ziggit.dev/t/equivalent-of-cs-date-and-time-macros/2076/2
        const now = zdt.Datetime.fromUnix(build.timestamp, zdt.Duration.Resolution.second, null) catch unreachable;
        const build_date_buf = allocator.alloc(u8, 64) catch unreachable;
        errdefer allocator.free(build_date_buf);
        var w = std.Io.Writer.fixed(build_date_buf);
        now.toString("%Y-%m-%d %H:%M:%S", &w) catch unreachable;
        // https://stackoverflow.com/questions/72736997/how-to-pass-a-c-string-into-a-zig-function-expecting-a-zig-string
        // https://dev.to/jmatth11/quick-zig-and-c-string-conversion-conundrums-203b
        const cimgui_version: []const u8 = std.mem.span(ig.igGetVersion()); // [0..]
        const libraw_version: []const u8 = std.mem.span(libraw.libraw_version()); // [0..]
        const build_date = w.buffered(); // or build_date_buf[0..];

        return .{
            .allocator = allocator,
            .is_open = true,
            .init_pos = ig.ImVec2{ .x = 10, .y = 10 },
            .init_size = ig.ImVec2{ .x = 300, .y = 400 },
            .cimgui_version = cimgui_version,
            .libraw_version = libraw_version,
            .build_date = build_date,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Free the resources
        allocator.free(self.build_date);
    }

    pub fn render(self: *Self) void {
        // if (!self.is_open) {
        //     return;
        // }

        const backend_name: [*c]const u8 = switch (sg.queryBackend()) {
            .D3D11 => "Direct3D11",
            .GLCORE => "OpenGL",
            .GLES3 => "OpenGLES3",
            .METAL_IOS => "Metal iOS",
            .METAL_MACOS => "Metal macOS",
            .METAL_SIMULATOR => "Metal Simulator",
            .WGPU => "WebGPU",
            .DUMMY => "Dummy",
        };

        ig.igSetNextWindowPosEx(self.init_pos, ig.ImGuiCond_Once, ig.ImVec2{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(self.init_size, ig.ImGuiCond_Once);
        // ig.igSetNextWindowCollapsed(true, ig.ImGuiCond_Once);

        _ = ig.igBegin("About", &self.is_open, ig.ImGuiWindowFlags_None);
        ig.igText("PIE: Peyton's Image Editor v0.0.0");

        // https://ziggit.dev/t/how-to-return-a-c-string-from-u8/4569/2
        var text_buf: [100]u8 = undefined;

        const zig_version_text = std.fmt.bufPrintZ(&text_buf, "zig version: {s}\n", .{builtin.zig_version_string}) catch unreachable;
        ig.igText(zig_version_text.ptr);

        const build_time_text = std.fmt.bufPrintZ(&text_buf, "build date: {s}", .{self.build_date}) catch unreachable;
        ig.igText(build_time_text.ptr);

        ig.igText("Graphics Backend: %s", backend_name);

        const cimgui_version_text = std.fmt.bufPrintZ(&text_buf, "cimgui version: {s}", .{self.cimgui_version}) catch unreachable;
        ig.igText(cimgui_version_text.ptr);

        // ig.igText(std.fmt("LibRaw version: {}", self.libraw_version));
        const libraw_version_text = std.fmt.bufPrintZ(&text_buf, "LibRaw version: {s}", .{self.libraw_version}) catch unreachable;
        ig.igText(libraw_version_text.ptr);

        // for backend in state.center_image_pixpipe.backends {
        //     ig.igText(std.fmt("Backend: {} {}", backend.name, backend.version));
        //     if (backend is cl.BackendCL) {
        //         ig.igText(std.fmt(" - {}", backend.device.*));
        //     }
        // }

        ig.igText("");
        ig.igText("Main Thread:");
        // ig.igText(std.fmt("FPS: {} ({}|{})", state.fg.fps, state.fg.fps_max(), state.fg.fps_min()));
        // ig.igPlotLinesFloatPtr("FPS", state.fg.fps_history.data, 100, 0, "", 0, 120, ig.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));
        // ig.igText(std.fmt("Duty cycle: {}%%", state.fg.duty_cycle * 100));
        // ig.igPlotLinesFloatPtr("Duty cycle", state.fg.duty_history.data, 100, 0, "", 0, 1, ig.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));

        ig.igEnd();
    }
};

test "About" {
    const allocator = std.testing.allocator;
    const about = About.init(allocator);
    defer about.deinit(allocator);
    try std.testing.expectEqual(about.is_open, true);

    // expect the first 2 digits of the year to be "20" and imgui version to be "1."
    // this test ensures the slice allocated for the zdt formatter does not
    // become a dangling pointer after leaving init() **and**
    // ensures there is mo memory leak from forgetting to free it
    // std.debug.print("about.build_date: {s}\n", .{about.build_date[0..2]});
    try std.testing.expectEqualSlices(u8, about.build_date[0..2], "20"[0..]);
    try std.testing.expectEqualSlices(u8, about.cimgui_version[0..2], "1."[0..]);
}
