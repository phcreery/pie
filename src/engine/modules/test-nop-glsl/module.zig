const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "test-nop-glsl",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
    },
    .init = null,
    .deinit = null,
    .readSource = null,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyROIOut = null,
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

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = shader_code,
        .temp_shader_language = .glsl, // TODO: remove this once we have a proper shader compilation pipeline
        .name = "test-nop-glsl",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = null,
            };
            break :init s;
        },
    };
    const node = try pipe.addNode(mod, node_desc);
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
