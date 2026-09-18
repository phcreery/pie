const History = @import("history.zig").History;
const HistoryConfig = @import("history.zig").HistoryConfig;
const Pipeline = @import("pipeline.zig").Pipeline;

pub fn PipelineHistory() type {
    return struct {
        fn super(field_ptr: *@This()) *Pipeline {
            return @alignCast(@fieldParentPtr("history", field_ptr));
        }
        const Self = @This();
        // pub fn increment(m: *@This()) void {
        //     const x: *T = @alignCast(@fieldParentPtr("counter", m));
        //     x._counter += 1;
        // }
        // pub fn reset(m: *@This()) void {
        //     const x: *T = @alignCast(@fieldParentPtr("counter", m));
        //     x._counter = 0;
        // }

        // ================================================
        // History undo / redo / rollback
        // ================================================

        /// Roll back to the given committed step (exclusive index). Reconstructs the
        /// graph from scratch by replaying every recorded delta up to `target`
        /// onto a cleared pipeline — the same model vkdt uses. Module names resolve
        /// against the registered repos. `history.setCursor(end)` mirrors the target.
        pub fn replayHistory(self: *Self, target: usize) !void {
            const pipe = super(self);
            const target_clamped = @min(target, pipe.history.count());

            // tear down the live graph
            pipe.clear();

            // replay committed deltas over the empty graph
            var scratch = std.heap.ArenaAllocator.init(pipe.allocator);
            defer scratch.deinit();
            const all = pipe.history.all();
            const end = @min(target_clamped, all.len);
            for (all[0..end], 0..) |item, i| {
                try serdes.apply(pipe, scratch.allocator(), item.line, i);
            }

            pipe.history.setCursor(end);
        }

        /// Undo one edit step and apply it to the live pipeline.
        pub fn undo(self: *Self) !void {
            const pipe = super(self);
            if (!pipe.history.canUndo()) return;
            try pipe.replayHistory(pipe.history.cursor - 1);
        }

        /// Redo one edit step and apply it to the live pipeline.
        pub fn redo(self: *Self) !void {
            const pipe = super(self);
            if (!pipe.history.canRedo()) return;
            try pipe.replayHistory(pipe.history.cursor + 1);
        }
    };
}
