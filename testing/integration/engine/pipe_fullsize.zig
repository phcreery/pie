const std = @import("std");
const pie = @import("pie");
const console = @import("console");

const gpu = pie.gpu;
const Pipeline = pie.Pipeline;

test "fullsize through pipeline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cp_out = console.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 128 * 1024 * 1024, // 128 MB
        .download_buffer_size_bytes = 128 * 1024 * 1024, // 128 MB
    };

    var pipeline = Pipeline.init(allocator, std.testing.io, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

    const mod_i_raw = try pipeline.addModule("i-raw", "01");
    const mod_format = try pipeline.addModule("format", "01");
    const mod_denoise = try pipeline.addModule("denoise", "01");
    const mod_demosaic = try pipeline.addModule("demosaic", "01");
    const mod_color = try pipeline.addModule("color", "01");
    const mod_filmcurv = try pipeline.addModule("filmcurv", "01");
    const mod_o_png = try pipeline.addModule("o-png", "01");

    try pipeline.setModuleParam(mod_i_raw, "filename", []const u8, "testing/images/DSC_6765.NEF");
    try pipeline.setModuleParam(mod_i_raw, "wb_mode", i32, 1);

    try pipeline.setModuleParam(mod_filmcurv, "colormode", i32, 1);
    try pipeline.setModuleParam(mod_filmcurv, "brightness", f32, 2.22);
    try pipeline.setModuleParam(mod_filmcurv, "contrast", f32, 1.0);
    try pipeline.setModuleParam(mod_filmcurv, "bias", f32, 0.0);

    try pipeline.setModuleParam(mod_o_png, "filename", []const u8, "testing/images/DSC_6765_debayered.png");

    try pipeline.connectModules(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModules(mod_format, "output", mod_denoise, "input");
    try pipeline.connectModules(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModules(mod_demosaic, "output", mod_color, "input");
    try pipeline.connectModules(mod_color, "output", mod_filmcurv, "input");
    try pipeline.connectModules(mod_filmcurv, "output", mod_o_png, "input");
    try pipeline.run();
}
