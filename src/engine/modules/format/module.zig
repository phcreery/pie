const api = @import("../api.zig");

pub var module: api.ModuleDesc = .{
    .name = "format",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16uint,
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
    .createNodes = createNodes,
};

const shader_code: []const u8 =
    \\enable f16;
    \\@group(1) @binding(0) var input:  texture_2d<u32>;
    \\@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    \\    var coords = vec2<i32>(global_id.xy);
    \\    let px = textureLoad(input, coords, 0);
    \\    let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a)) / 4096.0; // max_value
    \\    textureStore(output, coords, pxf);
    \\}
;
pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const roi_out = mod_output_sock.roi.?.div(4, 1);
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = try api.compileShader(pipe, shader_code),
        .name = "uint16_to_float16",
        .run_size = roi_out,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16uint,
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
