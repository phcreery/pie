const std = @import("std");
const pie = @import("pie");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;

test "fullsize through pipeline" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cp_out = pie.cli.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init();
    defer gpu_instance.deinit();

    const pipeline_config: pie.engine.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 128 * 1024 * 1024, // 128 MB
        .download_buffer_size_bytes = 128 * 1024 * 1024, // 128 MB
    };

    var pipeline = Pipeline.init(allocator, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

    const mod_i_raw = try pipeline.addModule(pie.engine.modules.i_raw.desc);
    const mod_format = try pipeline.addModule(pie.engine.modules.format.desc);
    const mod_denoise = try pipeline.addModule(pie.engine.modules.denoise.desc);
    const mod_demosaic = try pipeline.addModule(pie.engine.modules.demosaic.desc);
    const mod_color = try pipeline.addModule(pie.engine.modules.color.desc);
    const mod_o_png = try pipeline.addModule(pie.engine.modules.o_png.desc);

    try pipeline.connectModulesName(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModulesName(mod_format, "output", mod_denoise, "input");
    try pipeline.connectModulesName(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModulesName(mod_demosaic, "output", mod_color, "input");
    try pipeline.connectModulesName(mod_color, "output", mod_o_png, "input");
    try pipeline.run(aa);
}
