const std = @import("std");
const pie = @import("pie");
const TargetConfig = @import("../targets.zig").TargetConfig;

const Pipeline = pie.engine.Pipeline;
const Registry = pie.engine.modules.Registry;

pub const config: TargetConfig = .{
    .input_filename = "testing/images/DSC_6765.NEF",
    .name = "001_DSC_6765",
    .build = build,
};

fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipeline: *Pipeline,
    modules: *Registry,
    input_filename: []const u8,
    output_filename: []const u8,
) anyerror!void {
    _ = allocator;
    _ = io;

    const mod_i_raw = try pipeline.addModule(modules.get("i-raw").?);
    const mod_format = try pipeline.addModule(modules.get("format").?);
    const mod_denoise = try pipeline.addModule(modules.get("denoise").?);
    // const mod_whitebalance = try pipeline.addModule(modules.get("whitebalance").?);
    const mod_demosaic = try pipeline.addModule(modules.get("demosaic").?);
    const mod_crop = try pipeline.addModule(modules.get("crop").?);
    const mod_color = try pipeline.addModule(modules.get("color").?);
    const mod_filmcurv = try pipeline.addModule(modules.get("filmcurv").?);
    const mod_test_nop_glsl = try pipeline.addModule(modules.get("test-nop-glsl").?);
    const mod_test_nop_zig = try pipeline.addModule(modules.get("test-nop-zig").?);
    const mod_o_ppm = try pipeline.addModule(modules.get("o-ppm").?);

    try pipeline.setModuleParam(mod_i_raw, "filename", @as([]const u8, input_filename));
    try pipeline.setModuleParam(mod_i_raw, "wb_mode", @as(i32, 0));
    try pipeline.setModuleParam(mod_color, "wb_temp", @as(f32, 6500.0));
    try pipeline.setModuleParam(mod_color, "wb_tint", @as(f32, 0.0));
    try pipeline.setModuleParam(mod_filmcurv, "colormode", @as(i32, 1));
    try pipeline.setModuleParam(mod_filmcurv, "brightness", @as(f32, 3.8));
    try pipeline.setModuleParam(mod_filmcurv, "contrast", @as(f32, 1.3));
    try pipeline.setModuleParam(mod_filmcurv, "bias", @as(f32, 0.0));
    try pipeline.setModuleParam(mod_o_ppm, "filename", @as([]const u8, output_filename));

    try pipeline.connectModuleSocketsByHandleName(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_format, "output", mod_denoise, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_denoise, "output", mod_whitebalance, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_whitebalance, "output", mod_demosaic, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_demosaic, "output", mod_crop, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_crop, "output", mod_color, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_color, "output", mod_filmcurv, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_filmcurv, "output", mod_test_nop_glsl, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_test_nop_glsl, "output", mod_test_nop_zig, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_test_nop_zig, "output", mod_o_ppm, "input");
}
