const api = @import("../api.zig");

pub var desc: api.ModuleDesc = .{
    .name = "test-multiply",
    .type = .compute,
    // .params = init: {
    //     var p: [api.MAX_PARAMS_PER_MODULE]?api.Param = @splat(null);
    //     p[0] = .{ .name = "multiplier", .value = .{ .f32 = 3.0 } }; // intentionally incorrectly set to 3.0
    //     p[1] = .{ .name = "adder", .value = .{ .i32 = 3.0 } }; // intentionally incorrectly set to 3.0
    //     break :init p;
    // },
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "multiplier", .len = 1, .typ = .f32 }; // intentionally incorrectly set to 3.0
        p[1] = .{ .name = "adder", .len = 1, .typ = .f32 }; //f intentionally incorrectly set to 3
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
    .initParams = initParams,
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
    \\struct ImgParams {
    \\    white:  vec4<f32>,
    \\    black:  vec4<f32>,
    \\};
    \\@group(0) @binding(0) var<storage, read_write> params: Params;
    \\@group(0) @binding(1) var<uniform>         img_params: ImgParams;
    \\@group(1) @binding(0) var                      input : texture_2d<f32>;
    \\@group(1) @binding(1) var                      output: texture_storage_2d<rgba16float, write>;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    \\    let coords = vec2<i32>(global_id.xy);
    \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
    \\    pixel *= params.multiplier;
    \\    //pixel *= img_params.float;
    \\    //pixel *= img_params.v3.z;
    \\    //pixel *= img_params.m3x3[2][2];
    \\    //pixel += f32(params.adder);
    \\    textureStore(output, coords, pixel);
    \\}
;
// const shader_code: []const u8 =
//     \\#version 460
//     \\layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
//     \\layout(std140, set = 0, binding = 1) uniform params_t {
//     \\    float multiplier;
//     \\    int   adder;
//     \\} params;
//     \\layout(rgba16f, set = 1, binding = 0) uniform           image2D img_in;
//     \\layout(rgba16f, set = 1, binding = 1) uniform writeonly image2D img_out;
//     \\void main() {
//     \\    ivec2 ipos = ivec2(gl_GlobalInvocationID);
//     \\    if(any(greaterThanEqual(ipos, imageSize(img_out)))) return;
//     \\    //vec3 rgb = texelFetch(img_in, ipos, 0).rgb;
//     \\    vec3 rgb = imageLoad(img_in, ipos).rgb;
//     \\    rgb *= params.multiplier;
//     \\    rgb += float(params.adder);
//     \\    imageStore(img_out, ipos, vec4(rgb, 1.0));
//     \\}
// ;

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    var m = try api.getModule(pipe, mod);
    var p: [api.MAX_PARAMS_PER_MODULE]?api.Param = @splat(null);
    p[0] = try api.initParam(pipe, m.desc.params[0].?, 3.0);
    p[1] = try api.initParam(pipe, m.desc.params[1].?, 3.0);
    m.params = p;
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try pipe.addNode(mod, .{
        .type = .compute,
        .shader = shader_code,
        .name = "multiply",
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
    });
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
