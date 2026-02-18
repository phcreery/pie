const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;

fn libraw_dcraw_process(allocator: std.mem.Allocator, file: std.fs.File, target_filename: []const u8) !void {
    const file_info = try file.stat();

    // create buffer and read entire file into it
    var buf: []u8 = try allocator.alloc(u8, file_info.size);
    defer allocator.free(buf);
    _ = try file.read(buf[0..]);

    const libraw_rp = libraw.libraw_init(0);

    const ret = libraw.libraw_open_buffer(libraw_rp, buf.ptr, buf.len);
    if (ret != libraw.LIBRAW_SUCCESS) {
        return error.OpenFailed;
    }
    const ret2 = libraw.libraw_unpack(libraw_rp);
    if (ret2 != libraw.LIBRAW_SUCCESS) {
        return error.UnpackFailed;
    }
    // const ret3 = libraw.libraw_raw2image(libraw_rp);
    // if (ret3 != libraw.LIBRAW_SUCCESS) {
    //     return error.Raw2ImageFailed;
    // }

    libraw_rp.*.params.half_size = 1;
    const ret3 = libraw.libraw_dcraw_process(libraw_rp);
    if (ret3 != libraw.LIBRAW_SUCCESS) {
        return error.DcrawProcessFailed;
    }
    std.log.info("DCRAW processed successfully", .{});

    // libraw_dcraw_make_mem_image

    std.log.info("Writing to {s}", .{target_filename});
    const ret4 = libraw.libraw_dcraw_ppm_tiff_writer(libraw_rp, target_filename.ptr);
    if (ret4 != libraw.LIBRAW_SUCCESS) {
        return error.DcrawWriteFailed;
    }
}

test "targeting dcraw basic processing" {
    const allocator = std.testing.allocator;

    // DCRAW
    const input_filename = "testing/images/DSC_6765.NEF";
    const target_filename = "testing/integration/targets/001_DSC_6765/target.ppm";
    const file = try std.fs.cwd().openFile(input_filename, .{});
    try libraw_dcraw_process(allocator, file, target_filename);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cout = pie.cli.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

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
    const mod_o_ppm = try pipeline.addModule(pie.engine.modules.o_ppm.desc);

    try pipeline.connectModulesName(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModulesName(mod_format, "output", mod_denoise, "input");
    try pipeline.connectModulesName(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModulesName(mod_demosaic, "output", mod_color, "input");
    try pipeline.connectModulesName(mod_color, "output", mod_o_ppm, "input");
    try pipeline.run(aa);
}
