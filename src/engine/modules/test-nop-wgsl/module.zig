const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "test-nop-wgsl",
    .type = .compute,
    .params = &.{},
    .params_ui = &.{},
    .sockets = &.{
        .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
        },
        .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
        },
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyOut = null,
};

const shader_code: []const u8 =
    \\enable f16;
    \\@group(1) @binding(0) var input  : texture_2d<f32>;
    \\@group(1) @binding(1) var output : texture_storage_2d<rgba16float, write>;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    \\    let coords = vec2<i32>(global_id.xy);
    \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
    \\    textureStore(output, coords, pixel);
    \\}
;
pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNode(pipe, mod, .{
        .type = .compute,
        .shader = .{ .wgsl = .{ .string = shader_code } },
        .name = "nop",
        .sockets = &.{
            .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
            },
            .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
            },
        },
    });
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
