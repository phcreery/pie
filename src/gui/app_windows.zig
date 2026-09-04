const std = @import("std");
const use_docking = @import("build_options").docking;
const ig = if (use_docking) @import("cimgui_docking") else @import("cimgui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const builtin = @import("builtin");
const build = @import("build_options");
const zdt = @import("zdt");
const libraw = @import("libraw");

const util = @import("../mem.zig");

pub const About = struct {
    is_open: bool,
    init_pos: ig.ImVec2,
    init_size: ig.ImVec2,
    cimgui_version: []const u8,
    libraw_version: []const u8,
    build_date: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
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
            .is_open = true,
            .init_pos = .{ .x = 10, .y = 10 },
            .init_size = .{ .x = 300, .y = 400 },
            .cimgui_version = cimgui_version,
            .libraw_version = libraw_version,
            .build_date = build_date,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Free the resources
        allocator.free(self.build_date);
    }

    pub fn draw(self: *Self) void {
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
            .VULKAN => "Vulkan",
            .DUMMY => "Dummy",
        };

        ig.igSetNextWindowPosEx(
            self.init_pos,
            ig.ImGuiCond_Once,
            .{ .x = 0, .y = 0 },
        );
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

        ig.igText("");
        ig.igText("Main Thread:");
        // ig.igText(std.fmt("FPS: {} ({}|{})", state.fg.fps, state.fg.fps_max(), state.fg.fps_min()));
        // ig.igPlotLinesFloatPtr("FPS", state.fg.fps_history.data, 100, 0, "", 0, 120, ig.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));
        // ig.igText(std.fmt("Duty cycle: {}%%", state.fg.duty_cycle * 100));
        // ig.igPlotLinesFloatPtr("Duty cycle", state.fg.duty_history.data, 100, 0, "", 0, 1, ig.ImVec2{ .x = 0, .y = 80 }, @sizeOf(f32));

        ig.igEnd();
    }
};
