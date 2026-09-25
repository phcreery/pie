const api = @import("../api.zig");

pub const desc: api.ModuleDesc = .{
    .name = "test-nop-glsl",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
        };
        break :init s;
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyOut = null,
};

// In GLSL, this input must be a texture-only binding, not a combined sampler.
// The engine binds socket 0 as a texture view with no sampler object.
const shader_code: []const u8 =
    \\#version 450
    \\layout(set = 1, binding = 0) uniform texture2D input;
    \\layout(set = 1, binding = 1, rgba16f) uniform writeonly image2D output;
    \\layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
    \\void main() {
    \\    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    \\    vec4 pixel = texelFetch(input, coords, 0);
    \\    imageStore(output, coords, pixel);
    \\}
;

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = comptime .{
        .type = .compute,
        .shader = .{ .glsl = .{ .string = shader_code } },
        .name = "test-nop-glsl",
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
    };
    const node = try api.addNode(pipe, mod, node_desc);
    try api.setNodeRunSize(pipe, node, mod_output_sock.roi);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}
