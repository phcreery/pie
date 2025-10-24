const std = @import("std");
const gpu = @import("gpu.zig");

pub const Pipeline = struct {
    gpu: gpu.GPU,

    pub fn init() !Pipeline {
        return Pipeline{
            .gpu = try gpu.GPU.init(),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.gpu.deinit();
    }
};
