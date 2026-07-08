const std = @import("std");
const pie = @import("pie");
const TargetConfig = @import("../targets.zig").TargetConfig;

const Pipeline = pie.Pipeline;
const Repository = pie.modules.Repository;

pub const config: TargetConfig = .{
    .input_filename = "testing/images/DSC_6765.NEF",
    .name = "001_DSC_6765",
    .build = build,
};

fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipe: *Pipeline,
    repo: *Repository,
    input_filename: []const u8,
    output_filename: []const u8,
) anyerror!void {
    _ = allocator;
    _ = io;

    const mod_i_raw = try pipe.addModule(repo.get("i-raw").?);
    const mod_format = try pipe.addModule(repo.get("format").?);
    const mod_denoise = try pipe.addModule(repo.get("denoise").?);
    // const mod_whitebalance = try pipeline.addModule(modules.get("whitebalance").?);
    const mod_demosaic = try pipe.addModule(repo.get("demosaic").?);
    const mod_crop = try pipe.addModule(repo.get("crop").?);
    const mod_color = try pipe.addModule(repo.get("color").?);
    const mod_filmcurv = try pipe.addModule(repo.get("filmcurv").?);
    // const mod_test_nop_glsl = try pipeline.addModule(modules.get("test-nop-glsl").?);
    // const mod_test_nop_zig = try pipeline.addModule(modules.get("test-nop-zig").?);
    const mod_o_ppm = try pipe.addModule(repo.get("o-ppm").?);

    try pipe.setModuleParam(mod_i_raw, "filename", []const u8, input_filename);
    try pipe.setModuleParam(mod_i_raw, "wb_mode", i32, 0);
    // try pipeline.setModuleParam(mod_color, "wb_temp", f32, 6500.0);
    try pipe.setModuleParam(mod_color, "wb_tint", f32, 0.0);
    try pipe.setModuleParam(mod_color, "wb_coeff", [3]f32, .{ 0.70393723, 1, 1.3611937 }); // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    try pipe.setModuleParam(mod_filmcurv, "colormode", i32, 1);
    try pipe.setModuleParam(mod_filmcurv, "brightness", f32, 3.8);
    try pipe.setModuleParam(mod_filmcurv, "contrast", f32, 1.3);
    try pipe.setModuleParam(mod_filmcurv, "bias", f32, 0.0);
    try pipe.setModuleParam(mod_o_ppm, "filename", []const u8, output_filename);

    try pipe.connectModules(mod_i_raw, "output", mod_format, "input");
    try pipe.connectModules(mod_format, "output", mod_denoise, "input");
    // try pipeline.connectModules(mod_denoise, "output", mod_whitebalance, "input");
    // try pipeline.connectModules(mod_whitebalance, "output", mod_demosaic, "input");
    try pipe.connectModules(mod_denoise, "output", mod_demosaic, "input");
    try pipe.connectModules(mod_demosaic, "output", mod_crop, "input");
    try pipe.connectModules(mod_crop, "output", mod_color, "input");
    try pipe.connectModules(mod_color, "output", mod_filmcurv, "input");
    // try pipeline.connectModules(mod_filmcurv, "output", mod_test_nop_glsl, "input");
    // try pipeline.connectModules(mod_test_nop_glsl, "output", mod_test_nop_zig, "input");
    // try pipeline.connectModules(mod_test_nop_zig, "output", mod_o_ppm, "input");
    // try pipeline.connectModules(mod_test_nop_glsl, "output", mod_o_ppm, "input");
    try pipe.connectModules(mod_filmcurv, "output", mod_o_ppm, "input");
}
