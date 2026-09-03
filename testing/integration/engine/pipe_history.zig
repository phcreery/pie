const std = @import("std");
const pie = @import("pie");

const Pipeline = pie.Pipeline;
const P = pie.pipeline;
const CoalesceConfig = pie.history.CoalesceConfig;

/// Build a small chain through the history-aware ops so every step is recorded.
/// Relies on the given repo being registered on the pipeline already.
fn buildChain(p: *Pipeline) !struct {
    iraw: P.ModuleHandle,
    multiply: P.ModuleHandle,
    nop: P.ModuleHandle,
} {
    const iraw = try p.addModule("01", "test-i-1234");
    const multiply = try p.addModule("01", "test-multiply");
    const nop = try p.addModule("01", "test-nop-glsl");

    try p.setModuleParamWithHistory(multiply, "multiplier", f32, 1.0, .{});
    try p.setModuleParamWithHistory(multiply, "multiplier", f32, 2.0, .{});

    try p.connectModulesWithHistory(iraw, "output", multiply, "input", .{});
    try p.connectModulesWithHistory(multiply, "output", nop, "input", .{});

    return .{ .iraw = iraw, .multiply = multiply, .nop = nop };
}

fn newPipeline(allocator: std.mem.Allocator) !Pipeline {
    return try Pipeline.init(allocator, std.testing.io, null, null);
}

test "recorded history is an append-only delta log" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    const h = &pipeline.history;
    try std.testing.expectEqual(@as(usize, 0), h.count());
    try std.testing.expect(!h.canUndo());
    try std.testing.expect(!h.canRedo());

    _ = try buildChain(&pipeline);

    // 3 modules + 2 params + 2 connects = 7 steps
    try std.testing.expectEqual(@as(usize, 7), h.count());
    // all committed (cursor at tip)
    try std.testing.expectEqual(@as(usize, 7), h.committed().len);
    try std.testing.expect(h.canUndo());
    try std.testing.expect(!h.canRedo());

    // deltas are text lines in the pst grammar, values inline
    try std.testing.expectEqualStrings("module:test-i-1234:01", h.committed()[0].line);
    try std.testing.expectEqualStrings("module:test-multiply:01", h.committed()[1].line);
    try std.testing.expectEqualStrings("param:test-multiply:01:multiplier:1", h.committed()[3].line);
    try std.testing.expectEqualStrings("param:test-multiply:01:multiplier:2", h.committed()[4].line);
    try std.testing.expectEqualStrings("connect:test-i-1234:01:output:test-multiply:01:input", h.committed()[5].line);
    try std.testing.expectEqualStrings("connect:test-multiply:01:output:test-nop-glsl:01:input", h.committed()[6].line);
}

test "getModuleDesc resolves names from owned repo, addModule records" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    // the owned repo is auto-populated by init, so all built-in modules resolve
    try std.testing.expect(pipeline.getModuleDesc("test-i-1234") != null);
    // unknown names are not resolvable
    try std.testing.expect(pipeline.getModuleDesc("does-not-exist") == null);
    try std.testing.expectError(error.ModuleNotFound, pipeline.addModule("01", "does-not-exist"));

    // addModuleDesc (internal primitive) does NOT record
    _ = try pipeline.addModuleDesc("01", pipeline.getModuleDesc("test-i-1234").?);
    try std.testing.expectEqual(@as(usize, 0), pipeline.history.count());

    // addModule (public edit op) DOES record
    _ = try pipeline.addModule("02", "test-i-1234");
    try std.testing.expectEqual(@as(usize, 1), pipeline.history.count());
    try std.testing.expectEqualStrings("module:test-i-1234:02", pipeline.history.committed()[0].line);
}

test "coalescing merges repeated edits of the same param" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    const m = try pipeline.addModule("01", "test-multiply");

    // with coalesce enabled, two quick edits of 'multiplier' collapse to one step
    const cfg = CoalesceConfig{ .window_secs = 60.0 };
    try pipeline.setModuleParamWithHistory(m, "multiplier", f32, 1.0, cfg);
    const after_first = pipeline.history.count();
    try pipeline.setModuleParamWithHistory(m, "multiplier", f32, 2.0, cfg);
    try std.testing.expectEqual(after_first, pipeline.history.count());
    // the surviving step carries the most recent value, and the live pipeline follows
    try std.testing.expectEqualStrings("param:test-multiply:01:multiplier:2", @as([]const u8, pipeline.history.committed()[pipeline.history.committed().len - 1].line));
    const mod = try pipeline.module_pool.getPtr(m);
    try std.testing.expectEqual(@as(f32, 2.0), (try mod.getParamPtr("multiplier")).get(f32));

    // a different param or a coalesce-disabled call appends
    try pipeline.setModuleParamWithHistory(m, "multiplier", f32, 3.0, .{});
    try std.testing.expectEqual(after_first + 1, pipeline.history.count());
}

/// The multiply module's input socket is connected iff the connect delta (item 5)
/// has been replayed.
fn multiplyInputConnected(p: *Pipeline) bool {
    const m = p.module_name_map.get("test-multiply:01").?;
    const mod = p.module_pool.getPtr(m) catch return false;
    return mod.desc.sockets[0].?.private.connected_to_module != null;
}

test "undo/redo rebuild pipeline state via replay" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    const chain = try buildChain(&pipeline);
    _ = chain;
    const full_count = pipeline.history.count();

    const multiply_handle = pipeline.module_name_map.get("test-multiply:01").?;
    const mod_before = try pipeline.module_pool.getPtr(multiply_handle);
    try std.testing.expectEqual(@as(f32, 2.0), (try mod_before.getParamPtr("multiplier")).get(f32));
    try std.testing.expect(multiplyInputConnected(&pipeline));

    // undo one step (the last connect multiply->nop), replay
    try pipeline.undo();
    try std.testing.expectEqual(full_count - 1, pipeline.history.cursor);
    // there should be two connects left total; the last (multiply->nop) is undone,
    // but the earlier i1234->multiply connect is preserved.
    const nop_connected = blk: {
        const nop = pipeline.module_name_map.get("test-nop-glsl:01") orelse break :blk false;
        const mod = try pipeline.module_pool.getPtr(nop);
        break :blk mod.desc.sockets[0].?.private.connected_to_module != null;
    };
    try std.testing.expect(!nop_connected);
    try std.testing.expect(multiplyInputConnected(&pipeline));

    // redo restores it
    try pipeline.redo();
    try std.testing.expectEqual(full_count, pipeline.history.cursor);
    const nop_after = pipeline.module_name_map.get("test-nop-glsl:01").?;
    const modop2 = try pipeline.module_pool.getPtr(nop_after);
    try std.testing.expect(modop2.desc.sockets[0].?.private.connected_to_module != null);
    const mod_after_handle = pipeline.module_name_map.get("test-multiply:01").?;
    const mod_after = try pipeline.module_pool.getPtr(mod_after_handle);
    try std.testing.expectEqual(@as(f32, 2.0), (try mod_after.getParamPtr("multiplier")).get(f32));
}

test "replayHistory to arbitrary index yields that exact configuration" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    const chain = try buildChain(&pipeline);
    _ = chain;
    const full_count = pipeline.history.count();

    // jump back to index 4: the three modules are present (items 0..2), the
    // two param edits are replayed (items 3..4), but neither connect has run.
    try pipeline.replayHistory(4);
    try std.testing.expectEqual(@as(usize, 4), pipeline.history.cursor);
    try std.testing.expect(!multiplyInputConnected(&pipeline));
    const multiply_handle = pipeline.module_name_map.get("test-multiply:01").?;
    const mod = try pipeline.module_pool.getPtr(multiply_handle);
    // param value at the time: multiplier was first set to 1.0 (item 3)
    try std.testing.expectEqual(@as(f32, 1.0), (try mod.getParamPtr("multiplier")).get(f32));

    // roll forward past the second param and both connects back to the tip
    try pipeline.replayHistory(full_count);
    try std.testing.expectEqual(full_count, pipeline.history.cursor);
    try std.testing.expect(multiplyInputConnected(&pipeline));
    const mod2_handle = pipeline.module_name_map.get("test-multiply:01").?;
    const mod2 = try pipeline.module_pool.getPtr(mod2_handle);
    try std.testing.expectEqual(@as(f32, 2.0), (try mod2.getParamPtr("multiplier")).get(f32));
}

test "replay invalidates redo tail on new edits" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    const chain = try buildChain(&pipeline);
    _ = chain;
    const full = pipeline.history.count();

    try pipeline.undo();
    try std.testing.expectEqual(full - 1, pipeline.history.cursor);

    // a new edit after undo drops the redo tail
    const m = try pipeline.addModule("09", "test-i-1234");
    _ = m;
    try std.testing.expectEqual(full, pipeline.history.cursor);
    try std.testing.expectEqual(full, pipeline.history.count()); // nothing beyond cursor
    try std.testing.expect(!pipeline.history.canRedo());
}

test "history round-trips through serdes serialize output" {
    const allocator = std.testing.allocator;
    var pipeline = try Pipeline.init(allocator, std.testing.io, null, null);
    defer pipeline.deinit();

    _ = try buildChain(&pipeline);

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try pie.serdes.serialize(&pipeline, &w.writer);

    // The committed history lines must be a subset of the serialized graph
    // (replay 'delta log' + static serialize agree on the same grammar).
    const text = w.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "param:test-multiply:01:multiplier:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connect:test-multiply:01:output:test-nop-glsl:01:input") != null);
}
