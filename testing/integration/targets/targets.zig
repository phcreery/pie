const std = @import("std");
const pie = @import("pie");
const libraw = @import("libraw");
const zigimg = @import("zigimg");
const console = @import("console");

const gpu = pie.gpu;
const Pipeline = pie.Pipeline;

const PpmImage = struct {
    width: usize,
    height: usize,
    max_value: usize,
    pixels: []u8,

    fn deinit(self: *PpmImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

const ImageStats = struct {
    mean_rgb: [3]f64,
    mean_luma: f64,
};

const ComparisonScore = struct {
    mean_luma_target: f64,
    mean_luma_output: f64,
    mean_luma_abs_diff: f64,
    rss: f64,
    rmse: f64,
    nrmse: f64,
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn nextPpmToken(data: []const u8, index: *usize) ![]const u8 {
    while (index.* < data.len) {
        const c = data[index.*];
        if (isWhitespace(c)) {
            index.* += 1;
            continue;
        }
        if (c == '#') {
            while (index.* < data.len and data[index.*] != '\n') {
                index.* += 1;
            }
            continue;
        }
        break;
    }

    if (index.* >= data.len) return error.UnexpectedEndOfFile;

    const start = index.*;
    while (index.* < data.len and !isWhitespace(data[index.*])) {
        index.* += 1;
    }
    return data[start..index.*];
}

fn readPpmImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !PpmImage {
    const file_bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);
    errdefer allocator.free(file_bytes);

    var idx: usize = 0;
    const magic = try nextPpmToken(file_bytes, &idx);
    if (!std.mem.eql(u8, magic, "P6")) return error.UnsupportedPpmFormat;

    const width = try std.fmt.parseInt(usize, try nextPpmToken(file_bytes, &idx), 10);
    const height = try std.fmt.parseInt(usize, try nextPpmToken(file_bytes, &idx), 10);
    const max_value = try std.fmt.parseInt(usize, try nextPpmToken(file_bytes, &idx), 10);

    while (idx < file_bytes.len and isWhitespace(file_bytes[idx])) : (idx += 1) {}

    const expected_len = width * height * 3;
    if (file_bytes.len - idx < expected_len) return error.InvalidPpmData;

    const pixels = try allocator.alloc(u8, expected_len);
    @memcpy(pixels, file_bytes[idx .. idx + expected_len]);
    allocator.free(file_bytes);

    return .{
        .width = width,
        .height = height,
        .max_value = max_value,
        .pixels = pixels,
    };
}

fn computeImageStats(image: PpmImage) ImageStats {
    var rgb_sum = [3]f64{ 0.0, 0.0, 0.0 };
    var luma_sum: f64 = 0.0;
    const pixel_count = image.width * image.height;
    const pixel_count_f64 = @as(f64, @floatFromInt(pixel_count));

    for (0..pixel_count) |px| {
        const r = @as(f64, @floatFromInt(image.pixels[px * 3 + 0]));
        const g = @as(f64, @floatFromInt(image.pixels[px * 3 + 1]));
        const b = @as(f64, @floatFromInt(image.pixels[px * 3 + 2]));
        rgb_sum[0] += r;
        rgb_sum[1] += g;
        rgb_sum[2] += b;
        luma_sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    return .{
        .mean_rgb = .{
            rgb_sum[0] / pixel_count_f64,
            rgb_sum[1] / pixel_count_f64,
            rgb_sum[2] / pixel_count_f64,
        },
        .mean_luma = luma_sum / pixel_count_f64,
    };
}

fn readImageStats(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ImageStats {
    var image = try readPpmImage(allocator, io, path);
    defer image.deinit(allocator);
    return computeImageStats(image);
}

fn scorePpmOutputs(allocator: std.mem.Allocator, io: std.Io, target_filename: []const u8, output_filename: []const u8) !ComparisonScore {
    var target = try readPpmImage(allocator, io, target_filename);
    defer target.deinit(allocator);

    var output = try readPpmImage(allocator, io, output_filename);
    defer output.deinit(allocator);

    if (target.width != output.width or target.height != output.height) return error.ImageDimensionsMismatch;
    if (target.max_value != output.max_value) return error.ImageMaxValueMismatch;

    const target_stats = computeImageStats(target);
    const output_stats = computeImageStats(output);
    var sum_sq: f64 = 0.0;

    for (target.pixels, output.pixels) |t, o| {
        const tf = @as(f64, @floatFromInt(t));
        const of = @as(f64, @floatFromInt(o));
        const diff = of - tf;
        sum_sq += diff * diff;
    }

    const pixel_count_f64 = @as(f64, @floatFromInt(target.width * target.height));
    const channel_count_f64 = pixel_count_f64 * 3.0;
    const max_value_f64 = @as(f64, @floatFromInt(target.max_value));
    const rmse = @sqrt(sum_sq / channel_count_f64);
    const nrmse = rmse / max_value_f64;

    return .{
        .mean_luma_target = target_stats.mean_luma,
        .mean_luma_output = output_stats.mean_luma,
        .mean_luma_abs_diff = @abs(output_stats.mean_luma - target_stats.mean_luma),
        .rss = @sqrt(sum_sq),
        .rmse = rmse,
        .nrmse = nrmse,
    };
}

fn logImageStats(label: []const u8, stats: ImageStats) void {
    std.debug.print(
        "{s}: mean_rgb=({d:.3}, {d:.3}, {d:.3}) mean_luma={d:.3}\n",
        .{ label, stats.mean_rgb[0], stats.mean_rgb[1], stats.mean_rgb[2], stats.mean_luma },
    );
}

fn logComparisonScore(score: ComparisonScore) void {
    std.debug.print(
        "comparison: mean_luma target={d:.3} output={d:.3} abs_diff={d:.3} rss={d:.3} rmse={d:.3} nrmse={d:.6}\n",
        .{
            score.mean_luma_target,
            score.mean_luma_output,
            score.mean_luma_abs_diff,
            score.rss,
            score.rmse,
            score.nrmse,
        },
    );
}

fn libraw_dcraw_process(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_filename: []const u8,
    target_filename: []const u8,
    force: bool,
) !void {

    // first check if target_filename already exists, if so, skip processing
    if (!force) {
        if (std.Io.Dir.cwd().openFile(io, target_filename, .{})) |_| {
            std.log.info("Target file {s} already exists, skipping DCRAW processing", .{target_filename});
            return;
        } else |err| {
            if (err != std.Io.File.OpenError.FileNotFound) {
                return err;
            }
        }
    }

    std.log.info("DCRAW processing...", .{});

    const contents = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, input_filename, allocator, .unlimited);
    defer allocator.free(contents);

    const libraw_rp = libraw.libraw_init(0);

    const ret = libraw.libraw_open_buffer(libraw_rp, contents.ptr, contents.len);
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
    libraw_rp.*.params.use_camera_wb = 1;
    libraw_rp.*.params.use_camera_matrix = 1;
    libraw_rp.*.params.use_auto_wb = 0;
    // params.output_color=0 // 0 = sRGB, 1 = Adobe RGB, 2 = Wide Gamut RGB, 3 = ProPhoto RGB, 4 = XYZ, 5 = Raw
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

pub const TargetConfig = struct {
    input_filename: []const u8,
    name: []const u8,
    build: ?*const fn (
        allocator: std.mem.Allocator,
        io: std.Io,
        pipeline: *Pipeline,
        modules: *pie.modules.Repository,
        input_filename: []const u8,
        output_filename: []const u8,
    ) anyerror!void = null,
};

test "test targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cout = console.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    var gpu_instance = try gpu.GPU.init(io);
    defer gpu_instance.deinit();

    var modules = try pie.modules.Repository.init(allocator);
    defer modules.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 75e6,
        .download_buffer_size_bytes = 75e6,
    };

    var pipeline = Pipeline.init(allocator, io, &gpu_instance, pipeline_config) catch unreachable;
    defer pipeline.deinit();

    const config: TargetConfig = @import("001_DSC_6765/target.zig").config;
    const target_filename = "testing/integration/targets/" ++ config.name ++ "/target.ppm";
    const input_filename = config.input_filename;
    const output_filename = "testing/integration/targets/" ++ config.name ++ "/output.ppm";

    try libraw_dcraw_process(allocator, io, input_filename, target_filename, false);

    if (config.build) |build_fn| {
        try build_fn(allocator, io, &pipeline, &modules, input_filename, output_filename);
    } else {
        return error.NoBuildFunction;
    }

    try pipeline.run(arena);

    const target_stats = try readImageStats(allocator, io, target_filename);
    const output_stats = try readImageStats(allocator, io, output_filename);
    logImageStats("target", target_stats);
    logImageStats("output", output_stats);

    const score = try scorePpmOutputs(allocator, io, target_filename, output_filename);
    logComparisonScore(score);
}
