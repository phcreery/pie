const api = @import("../../api.zig");

pub const module: api.ModuleDesc = .{
    .name = "Create Test Data Module",
    .type = .source,
    // .param_ui = "",
    // .param_uniform = "",
    .output_socket = .{
        .name = "output",
        .type = .source,
        .format = .rgba16float,
        .roi = null,
    },
    .init = null,
    .deinit = null,
    .readSource = readSource,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyROIOut = modifyROIOut,
};

const source = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
const roi: api.ROI = .{
    .size = .{
        .w = 1,
        .h = 1,
    },
    .origin = .{
        .x = 0,
        .y = 0,
    },
};

pub fn modifyROIOut(pipe: *api.Pipeline, mod: *api.Module) !void {
    _ = pipe;
    mod.desc.output_socket.?.roi = roi;
}

pub fn readSource(
    pipe: *api.Pipeline,
    mod: *api.Module,
    // allocator: *gpu.GPUAllocator,
    mapped: *anyopaque,
) !void {
    _ = pipe;
    _ = mod;

    // allocator.upload(f16, &source, .rgba16float, roi);
    @memcpy(mapped, &source);
}

pub fn createNodes(pipe: *api.Pipeline, mod: *api.Module) !void {
    _ = pipe;
    const same_as_mod_output_sock = mod.getSocket("output") orelse unreachable;
    const node_desc: api.NodeDesc = .{
        .type = .source,
        .shader_code = "",
        .entry_point = "Test Data Source",
        .run_size = null,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = same_as_mod_output_sock;
            break :init s;
        },
    };
    const node = try api.addNodeDesc(mod, node_desc);
    try api.copyConnector(mod, "output", node, "output");
}
