const sokol = @import("sokol");
const shd = @import("texview_shader");
const sg = sokol.gfx;
const sapp = sokol.app;
const std = @import("std");
const pie = @import("pie");
const Image = @import("../components/image.zig").Image;
const ModulesPanel = @import("../components/modules_panel.zig").ModulesPanel;

const GUI = @import("../root.zig").GUI;

pub const Darkroom = struct {
    image: Image,
    image_loaded: bool = false,
    modules_panel: ModulesPanel,

    /// set by the modules panel when a param changed; consumed each update
    rerun_requested: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, gpu: *pie.GPU) !Self {
        const image = try Image.init(allocator, io, gpu);
        const modules_panel = ModulesPanel.init();
        return .{
            .image = image,
            .modules_panel = modules_panel,
        };
    }
    pub fn deinit(self: *Self) void {
        self.image.deinit();
    }
    pub fn update(self: *Self, gui: *GUI) void {
        // Logic + compute (pipeline run) must happen *outside* the sokol
        // render pass: WebGPU disallows buffer mapAsync/queue.submit while a
        // render command encoder is open ("Concurrent buffer operations").

        if (!self.image_loaded) {
            std.debug.print("building texture", .{});
            // set up the pipeline graph once, run it, and inject the texture
            const texture = build_image(gui.allocator, gui.io, &self.image.pipeline) catch unreachable;
            std.debug.print("texture: {any}\n", .{texture});
            self.image.createFrom(texture);
            self.image_loaded = true;
        }

        // consume any param edits from the modules panel
        if (self.rerun_requested) {
            self.rerun_requested = false;
            var arena_instance = std.heap.ArenaAllocator.init(gui.allocator);
            defer arena_instance.deinit();
            self.image.pipeline.run(arena_instance.allocator()) catch {};
            const texture = self.image.pipeline.getDisplaySinkTexture() catch null;
            if (texture) |t| {
                // re-inject (texture may have been reallocated on a rerouted run)
                self.image.refreshFrom(t);
            }
        }
    }
    pub fn draw(self: *Self, gui: *GUI) void {
        _ = gui;
        self.image.draw();
        self.modules_panel.draw(&self.image.pipeline, &self.rerun_requested);
    }
    pub fn event(self: *Self, gui: *GUI, ev: [*c]const sapp.Event) void {
        _ = gui;
        self.image.event(ev);
    }
};

fn build_image(allocator: std.mem.Allocator, io: std.Io, pipeline: *pie.pipeline.Pipeline) !*pie.gpu.Texture {
    _ = io;

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const input_filename = "testing/images/DSC_6765.NEF";

    const mod_i_raw = try pipeline.addModule("01", "i-raw");
    const mod_format = try pipeline.addModule("01", "format");
    const mod_denoise = try pipeline.addModule("01", "denoise");
    const mod_demosaic = try pipeline.addModule("01", "demosaic");
    const mod_crop = try pipeline.addModule("01", "crop");
    const mod_color = try pipeline.addModule("01", "color");
    const mod_filmcurv = try pipeline.addModule("01", "filmcurv");
    const mod_o_display = try pipeline.addModule("01", "o-display");

    try pipeline.setModuleParam(mod_i_raw, "filename", []const u8, input_filename);
    try pipeline.setModuleParam(mod_i_raw, "wb_mode", i32, 0);
    try pipeline.setModuleParam(mod_color, "wb_tint", f32, 0.0);
    try pipeline.setModuleParam(mod_color, "wb_coeff", [3]f32, .{ 0.70393723, 1, 1.3611937 }); // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    try pipeline.setModuleParam(mod_filmcurv, "colormode", i32, 1);
    try pipeline.setModuleParam(mod_filmcurv, "brightness", f32, 3.8);
    try pipeline.setModuleParam(mod_filmcurv, "contrast", f32, 1.3);
    try pipeline.setModuleParam(mod_filmcurv, "bias", f32, 0.0);

    try pipeline.connectModules(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModules(mod_format, "output", mod_denoise, "input");
    try pipeline.connectModules(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModules(mod_demosaic, "output", mod_crop, "input");
    try pipeline.connectModules(mod_crop, "output", mod_color, "input");
    try pipeline.connectModules(mod_color, "output", mod_filmcurv, "input");
    try pipeline.connectModules(mod_filmcurv, "output", mod_o_display, "input");

    try pipeline.run(arena);

    const disp_tex = try pipeline.getDisplaySinkTexture();
    // Use the display texture for rendering
    return disp_tex;
}
