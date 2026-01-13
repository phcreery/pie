const std = @import("std");
const pie = @import("pie");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;

test "fullsize through pipeline" {
    const allocator = std.testing.allocator;

    const cp_out = pie.cli.console.UTF8ConsoleOutput.init();
    defer cp_out.deinit();

    var gpu_instance = try gpu.GPU.init();
    defer gpu_instance.deinit();

    const pipeline_config: pie.engine.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024 * 1024 * 1024, // 1 GB
        .download_buffer_size_bytes = 1024 * 1024 * 1024, // 1 GB
    };

    var pipeline = Pipeline.init(allocator, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

    const mod_i_raw = try pipeline.addModule(pie.engine.modules.i_raw.module);
    const mod_format = try pipeline.addModule(pie.engine.modules.format.module);
    const mod_test_o_firstbytes = try pipeline.addModule(pie.engine.modules.test_o_firstbytes.module);

    pipeline.connectModulesName(mod_i_raw, "output", mod_format, "input") catch unreachable;
    pipeline.connectModulesName(mod_format, "output", mod_test_o_firstbytes, "input") catch unreachable;

    try pipeline.run();
}
