const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "test-i-1234",
    .type = .source,
    .params = &.{},
    .params_ui = &.{},
    .sockets = &.{
        .{
            .name = "output",
            .type = .source,
            .format = .rgba16float,
        },
    },
    .init = null,
    .deinit = null,
    .readSource = readSource,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyOut = modifyOut,
};

const source = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
const roi: api.ROI = .{
    .w = 1,
    .h = 1,
};

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    var socket = try api.getModSocket(pipe, mod, "output");
    socket.roi = roi;

    var m = try api.getModule(pipe, mod);
    m.img_param = .{
        .white = .{ 1.0, 2.0, 3.0, 4.0 },
        .black = .{ 1.0, 2.0, 3.0, 4.0 },
        .white_balance = .{ 1.0, 1.0, 1.0, 1.0 },
        // .rec2020_from_cam = .{
        //     .{ 1.0, 0.0, 0.0 },
        //     .{ 0.0, 1.0, 0.0 },
        //     .{ 0.0, 0.0, 1.0 },
        // },
        .srgb_from_cam = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        },
        .orientation = .normal,
        .xyz_d65_from_cam = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        },
    };
}

pub fn readSource(pipe: api.PipelineHandle, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    _ = pipe;
    _ = mod;

    const upload_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
    // const upload_buffer_slice = upload_buffer_ptr[0..(roi.w * roi.h * 4)];
    @memcpy(upload_buffer_ptr, &source);
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const node = try api.addNode(pipe, mod, .{
        .type = .source,
        .name = "source",
        .sockets = &.{
            .{
                .name = "output",
                .type = .source,
                .format = .rgba16float,
            },
        },
    });
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
