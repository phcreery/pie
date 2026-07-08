const sokol = @import("sokol");
const shd = @import("texview_shader");
const sg = sokol.gfx;
const sapp = sokol.app;
const std = @import("std");
const pie = @import("pie");
const Image = @import("../components/image.zig").Image;

pub const Darkroom = struct {
    image: Image,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, gpu: *pie.GPU, repo: *pie.modules.Repository) Self {
        var self: Self = .{
            .image = .init(allocator, io, gpu),
            // .gpu = gpu, // save for later
        };
        // run pipeline and webgpu inject texture
        const texture = build_image(
            allocator,
            io,
            &self.image.pipeline,
            repo,
        ) catch unreachable;
        std.debug.print("texture: {any}\n", .{texture});
        self.image.createFrom(texture);
        return self;
    }
    pub fn deinit(self: *Self) void {
        self.image.deinit();
    }
    pub fn draw(self: *Self) void {
        self.image.draw();
    }
    pub fn event(self: *Self, ev: [*c]const sapp.Event) void {
        self.image.event(ev);
    }
};

fn build_image(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipeline: *pie.pipeline.Pipeline,
    repo: *pie.modules.Repository,
) !*pie.gpu.Texture {
    _ = io;

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const input_filename = "testing/images/DSC_6765.NEF";

    const mod_i_raw = try pipeline.addModuleFromRepo(repo, "i-raw");
    const mod_format = try pipeline.addModuleFromRepo(repo, "format");
    const mod_denoise = try pipeline.addModuleFromRepo(repo, "denoise");
    const mod_demosaic = try pipeline.addModuleFromRepo(repo, "demosaic");
    const mod_crop = try pipeline.addModuleFromRepo(repo, "crop");
    const mod_color = try pipeline.addModuleFromRepo(repo, "color");
    const mod_filmcurv = try pipeline.addModuleFromRepo(repo, "filmcurv");
    const mod_o_display = try pipeline.addModuleFromRepo(repo, "o-display");

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
