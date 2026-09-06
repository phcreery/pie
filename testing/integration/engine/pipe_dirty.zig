const std = @import("std");
const pie = @import("pie");

const Pipeline = pie.Pipeline;
const P = pie.pipeline;

/// Helper: read a node's run_count by scanning the node pool for a node whose
/// desc name matches (there is one node per module in this test chain).
fn runCount(p: *Pipeline, name: []const u8) u32 {
    var it = p.node_pool.liveHandles();
    while (it.next()) |h| {
        const n = p.node_pool.getPtr(h) catch continue;
        if (std.mem.eql(u8, n.desc.name, name)) return n.run_count;
    }
    return 0;
}

test "param change only re-runs the dirty module node and its downstream successors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_i = try pipeline.addModule("01", "test-i-1234");
    const mod_mult = try pipeline.addModule("01", "test-multiply");
    const mod_nop = try pipeline.addModule("01", "test-nop-glsl");
    const mod_o = try pipeline.addModule("01", "test-o-2468");

    try pipeline.setModuleParam(mod_mult, "multiplier", f32, 2.0);

    try pipeline.connectModules(mod_i, "output", mod_mult, "input");
    try pipeline.connectModules(mod_mult, "output", mod_nop, "input");
    try pipeline.connectModules(mod_nop, "output", mod_o, "input");

    // ---- first run: everything runs once ----
    try pipeline.run(aa);
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "test-nop-glsl"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "sink"));

    // ---- change 'adder' on multiply (does not affect sink output which expects 2x) ----
    // only multiply + downstream (nop-glsl, sink) should re-run; source must NOT.
    try pipeline.setModuleParam(mod_mult, "adder", f32, 5.0);
    try pipeline.run(aa);

    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source")); // source must not re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "multiply")); // multiply must re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "test-nop-glsl")); // downstream must re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "sink")); // downstream must re-run

    // ---- a param change that doesn't touch anything: same dirty count ----
    try pipeline.setModuleParam(mod_mult, "adder", f32, 6.0);
    try pipeline.run(aa);
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source"));
    try std.testing.expectEqual(@as(u32, 3), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 3), runCount(&pipeline, "test-nop-glsl"));
    try std.testing.expectEqual(@as(u32, 3), runCount(&pipeline, "sink"));
}

test "changing a mid-chain param does not re-run upstream nodes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 1024,
        .download_buffer_size_bytes = 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_i = try pipeline.addModule("01", "test-i-1234");
    const mod_mult = try pipeline.addModule("01", "test-multiply");
    const mod_o = try pipeline.addModule("01", "test-o-2468");

    try pipeline.setModuleParam(mod_mult, "multiplier", f32, 2.0);

    try pipeline.connectModules(mod_i, "output", mod_mult, "input");
    try pipeline.connectModules(mod_mult, "output", mod_o, "input");

    try pipeline.run(aa);
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "sink"));

    // change adder on multiply; source (i-1234) must stay at 1 run
    try pipeline.setModuleParam(mod_mult, "adder", f32, 4.0);
    try pipeline.run(aa);

    try std.testing.expectEqual(@as(u32, 1), runCount(&pipeline, "source")); // source upstream not re-run
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "multiply"));
    try std.testing.expectEqual(@as(u32, 2), runCount(&pipeline, "sink"));
}

test "swap-roi output change refreshes connector texture and re-runs downstream" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var gpu_instance = try pie.gpu.GPU.init(allocator, io);
    defer gpu_instance.deinit();

    // large buffers for the full-size raw image
    const config: P.PipelineConfig = .{
        .upload_buffer_size_bytes = 200 * 1024 * 1024,
        .download_buffer_size_bytes = 200 * 1024 * 1024,
    };
    var pipeline = try Pipeline.init(allocator, io, &gpu_instance, config);
    defer pipeline.deinit();

    const mod_raw = try pipeline.addModule("01", "i-raw");
    const mod_format = try pipeline.addModule("01", "format");
    const mod_demosaic = try pipeline.addModule("01", "demosaic");
    const mod_disp = try pipeline.addModule("01", "o-display");
    const mod_swap = try pipeline.addModule("01", "test-swap-roi"); // todo: swap with crop module

    try pipeline.setModuleParam(mod_raw, "filename", []const u8, "testing/images/DSC_6765.NEF");

    try pipeline.connectModules(mod_raw, "output", mod_format, "input");
    try pipeline.connectModules(mod_format, "output", mod_swap, "input");
    try pipeline.connectModules(mod_swap, "output", mod_demosaic, "input");
    try pipeline.connectModules(mod_demosaic, "output", mod_disp, "input");

    // run 1: swap off -> output roi == raw sensor dims 4016x6016
    try pipeline.run(aa);
    const first_roi = blk: {
        var node_it = pipeline.node_pool.liveHandles();
        while (node_it.next()) |h| {
            const n = try pipeline.node_pool.getPtr(h);
            if (std.mem.eql(u8, n.desc.name, "swap-roi")) {
                const ch = pipeline.getNodeConnectorHandle(n.desc.sockets[1].?) orelse return error.TestUnexpectedResult;
                const c = try pipeline.connector_pool.getPtr(ch);
                break :blk c.texture.?.roi;
            }
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u32, 6016), first_roi.w);
    try std.testing.expectEqual(@as(u32, 4016), first_roi.h);

    // run 2: swap on -> output roi becomes 6016x4016 (w/h swapped) -> texture refresh
    try pipeline.setModuleParam(mod_swap, "swap_roi", i32, 1);
    try pipeline.run(aa);
    const second_roi = blk: {
        var node_it = pipeline.node_pool.liveHandles();
        while (node_it.next()) |h| {
            const n = try pipeline.node_pool.getPtr(h);
            if (std.mem.eql(u8, n.desc.name, "swap-roi")) {
                const ch = pipeline.getNodeConnectorHandle(n.desc.sockets[1].?) orelse return error.TestUnexpectedResult;
                const c = try pipeline.connector_pool.getPtr(ch);
                break :blk c.texture.?.roi;
            }
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u32, 4016), second_roi.w); // swapped
    try std.testing.expectEqual(@as(u32, 6016), second_roi.h);

    // sink (o-display) must have re-run into the new texture
    try std.testing.expect(runCount(&pipeline, "o-display") >= 2);
}
