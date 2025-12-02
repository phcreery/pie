const api = @import("../api.zig");

pub var module: api.ModuleDesc = .{
    .name = "test-multiply",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.Param = @splat(null);
        p[0] = .{ .name = "multiplier", .value = .{ .f32 = 3.0 } }; // intentionally incorrectly set to 3.0
        p[1] = .{ .name = "adder", .value = .{ .i32 = 3.0 } }; // intentionally incorrectly set to 3.0
        break :init p;
    },
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

const shader_code: []const u8 =
    \\enable f16;
    \\struct Params {
    \\    multiplier: f32,
    \\    adder:      i32,
    \\};
    \\@group(0) @binding(0) var                      input:  texture_2d<f32>;
    \\@group(0) @binding(1) var                      output: texture_storage_2d<rgba16float, write>;
    \\@group(1) @binding(0) var<storage, read_write> params: Params;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn multiply(@builtin(global_invocation_id) global_id: vec3<u32>) {
    \\    let coords = vec2<i32>(global_id.xy);
    \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
    \\    pixel *= params.multiplier;
    \\    pixel += f32(params.adder);
    \\    textureStore(output, coords, pixel);
    \\}
;
pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = api.getModSocket(pipe, mod, "output") orelse unreachable;
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader_code = shader_code,
        .entry_point = "multiply",
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
