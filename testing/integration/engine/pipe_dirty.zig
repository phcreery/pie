const std = @import("std");
const pie = @import("pie");

const Pipeline = pie.Pipeline;
const P = pie.pipeline;

/// Helper: read a node's run count from the perf metrics by scanning the node
/// pool for a node with a matching name (there is one node per module here).
fn runCount(p: *Pipeline, name: []const u8) u32 {
    var it = p.node_pool.liveHandles();
    while (it.next()) |h| {
        const n = p.node_pool.getPtr(h) catch continue;
        if (std.mem.eql(u8, n.name, name)) return p.perf.runCount(h);
    }
    return 0;
}

test "param change only re-runs the dirty module node and its downstream successors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_i = try pipeline.addModule("test-i-1234", "01");
    const mod_mult = try pipeline.addModule("test-multiply", "01");
    const mod_nop = try pipeline.addModule("test-nop-glsl", "01");
    const mod_o = try pipeline.addModule("test-o-2468", "01");

    try pipeline.setModuleParam(mod_mult, "multiplier", f32, 2.0);

    try pipeline.connectModules(mod_i, "output", mod_mult, "input");
    try pipeline.connectModules(mod_mult, "output", mod_nop, "input");
    try pipeline.connectModules(mod_nop, "output", mod_o, "input");

    // ---- first run: everything runs once ----
    try pipeline.run();
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "test-nop-glsl"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "sink"));
    // one pipeline + bind group per compute node, built once
    try std.testing.expectEqual(@as(usize, 2), pipeline.perf.n_pipelines_created orelse 0);
    try std.testing.expectEqual(@as(usize, 2), pipeline.perf.n_bindings_created orelse 0);

    // ---- change 'adder' on multiply (does not affect sink output which expects 2x) ----
    // only multiply + downstream (nop-glsl, sink) should re-run; source must NOT.
    try pipeline.setModuleParam(mod_mult, "adder", f32, 5.0);
    try pipeline.run();

    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source")); // source must not re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "multiply")); // multiply must re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "test-nop-glsl")); // downstream must re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "sink")); // downstream must re-run
    // a parameter edit rewrites the already-bound param buffer; it must not
    // rebuild any pipeline or bind group
    try std.testing.expectEqual(@as(usize, 0), pipeline.perf.n_pipelines_created orelse 0);
    try std.testing.expectEqual(@as(usize, 0), pipeline.perf.n_bindings_created orelse 0);

    // ---- a param change that doesn't touch anything: same dirty count ----
    try pipeline.setModuleParam(mod_mult, "adder", f32, 6.0);
    try pipeline.run();
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source"));
    try std.testing.expectEqual(@as(u32, 3), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 3), runCount(&pipeline, "test-nop-glsl"));
    try std.testing.expectEqual(@as(u32, 3), runCount(&pipeline, "sink"));
    // repeated drags keep hitting the cache
    try std.testing.expectEqual(@as(usize, 0), pipeline.perf.n_pipelines_created orelse 0);
    try std.testing.expectEqual(@as(usize, 0), pipeline.perf.n_bindings_created orelse 0);
}

test "changing a mid-chain param does not re-run upstream nodes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_i = try pipeline.addModule("test-i-1234", "01");
    const mod_mult = try pipeline.addModule("test-multiply", "01");
    const mod_o = try pipeline.addModule("test-o-2468", "01");

    try pipeline.setModuleParam(mod_mult, "multiplier", f32, 2.0);

    try pipeline.connectModules(mod_i, "output", mod_mult, "input");
    try pipeline.connectModules(mod_mult, "output", mod_o, "input");

    try pipeline.run();
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "sink"));
    try std.testing.expectEqual(@as(usize, 1), pipeline.perf.n_pipelines_created orelse 0);
    try std.testing.expectEqual(@as(usize, 1), pipeline.perf.n_bindings_created orelse 0);

    // change adder on multiply; source (i-1234) must stay at 1 run
    try pipeline.setModuleParam(mod_mult, "adder", f32, 4.0);
    try pipeline.run();

    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source")); // source upstream not re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "sink"));
    try std.testing.expectEqual(@as(usize, 0), pipeline.perf.n_pipelines_created orelse 0);
    try std.testing.expectEqual(@as(usize, 0), pipeline.perf.n_bindings_created orelse 0);
}

test "swap-roi output change refreshes connector texture and re-runs downstream" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    // large buffers for the full-size raw image
    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 200 * 1024 * 1024,
        .download_buffer_size_bytes = 200 * 1024 * 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_raw = try pipeline.addModule("i-raw", "01");
    const mod_format = try pipeline.addModule("format", "01");
    const mod_demosaic = try pipeline.addModule("demosaic", "01");
    const mod_disp = try pipeline.addModule("o-display", "01");
    const mod_swap = try pipeline.addModule("test-swap-roi", "01"); // todo: swap with crop module

    try pipeline.setModuleParam(mod_raw, "filename", []const u8, "testing/images/DSC_6765.NEF");

    try pipeline.connectModules(mod_raw, "output", mod_format, "input");
    try pipeline.connectModules(mod_format, "output", mod_swap, "input");
    try pipeline.connectModules(mod_swap, "output", mod_demosaic, "input");
    try pipeline.connectModules(mod_demosaic, "output", mod_disp, "input");

    // run 1: swap off -> output roi == raw sensor dims 4016x6016
    try pipeline.run();
    const first_roi = blk: {
        var node_it = pipeline.node_pool.liveHandles();
        while (node_it.next()) |h| {
            const n = try pipeline.node_pool.getPtr(h);
            if (std.mem.eql(u8, n.name, "swap-roi")) {
                const ch = pipeline.getNodeSocketConnectorHandle(n.sockets[1].?) orelse return error.TestUnexpectedResult;
                const c = try pipeline.connector_pool.getPtr(ch);
                break :blk switch (c.data orelse return error.TestUnexpectedResult) {
                    .texture => |tex| tex.roi,
                    .buffer => return error.TestUnexpectedResult,
                };
            }
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u32, 6016), first_roi.w);
    try std.testing.expectEqual(@as(u32, 4016), first_roi.h);

    // run 2: swap on -> output roi becomes 6016x4016 (w/h swapped) -> texture refresh
    try pipeline.setModuleParam(mod_swap, "swap_roi", i32, 1);
    try pipeline.run();
    const second_roi = blk: {
        var node_it = pipeline.node_pool.liveHandles();
        while (node_it.next()) |h| {
            const n = try pipeline.node_pool.getPtr(h);
            if (std.mem.eql(u8, n.name, "swap-roi")) {
                const ch = pipeline.getNodeSocketConnectorHandle(n.sockets[1].?) orelse return error.TestUnexpectedResult;
                const c = try pipeline.connector_pool.getPtr(ch);
                break :blk switch (c.data orelse return error.TestUnexpectedResult) {
                    .texture => |tex| tex.roi,
                    .buffer => return error.TestUnexpectedResult,
                };
            }
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u32, 4016), second_roi.w); // swapped
    try std.testing.expectEqual(@as(u32, 6016), second_roi.h);

    // the ROI change replaced a connector texture, which must invalidate the
    // cached pipelines/bind groups that referenced it
    try std.testing.expect((pipeline.perf.n_pipelines_created orelse 0) > 0);
    try std.testing.expect((pipeline.perf.n_bindings_created orelse 0) > 0);

    // sink (o-display) must have re-run into the new texture
    try std.testing.expect(runCount(&pipeline, "o-display") >= 2);
}

test "param staging and copies only cover modules whose params changed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_i = try pipeline.addModule("test-i-1234", "01");
    const mod_a = try pipeline.addModule("test-multiply", "01");
    const mod_b = try pipeline.addModule("test-multiply", "02");
    const mod_o = try pipeline.addModule("test-o-2468", "01");

    try pipeline.connectModules(mod_i, "output", mod_a, "input");
    try pipeline.connectModules(mod_a, "output", mod_b, "input");
    try pipeline.connectModules(mod_b, "output", mod_o, "input");

    // the sink asserts 2x; keep the product at 2 across both modules
    try pipeline.setModuleParam(mod_a, "multiplier", f32, 2.0);
    try pipeline.setModuleParam(mod_b, "multiplier", f32, 1.0);

    // first run stages and copies both modules' params
    try pipeline.run();
    try std.testing.expectEqual(@as(usize, 2), pipeline.perf.n_param_uploads orelse 0);
    try std.testing.expectEqual(@as(usize, 2), pipeline.perf.n_param_copies orelse 0);

    // editing one module re-packs and re-copies only that module
    try pipeline.setModuleParam(mod_a, "adder", f32, 1.0);
    try pipeline.run();
    try std.testing.expectEqual(@as(usize, 1), pipeline.perf.n_param_uploads orelse 0);
    try std.testing.expectEqual(@as(usize, 1), pipeline.perf.n_param_copies orelse 0);

    // and the other module likewise (the unused 'adder' keeps the sink at 2x)
    try pipeline.setModuleParam(mod_b, "adder", f32, 1.0);
    try pipeline.run();
    try std.testing.expectEqual(@as(usize, 1), pipeline.perf.n_param_uploads orelse 0);
    try std.testing.expectEqual(@as(usize, 1), pipeline.perf.n_param_copies orelse 0);
}
