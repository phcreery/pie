const api = @import("../api.zig");

/// Test-only module: a passthrough compute (copy input -> output) whose output
/// ROI is `input_roi` when `swap_roi == 0`, or `(h, w)` when `swap_roi == 1`.
/// Used to exercise the pipeline's connector-texture refresh path when an output
/// roi changes (modifyOut).
pub var desc: api.ModuleDesc = .{
    .name = "test-swap-roi",
    .type = .compute,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "swap_roi", .len = 1, .typ = .i32 };
        break :init p;
    },
    .params_ui = init: {
        var ui: [api.MAX_PARAMS_PER_MODULE]?api.ParamUI = @splat(null);
        ui[0] = .{ .name = "swap_roi", .control = .{ .checkbox = {} } };
        break :init ui;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb16float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rggb16float,
            .roi = null,
        };
        break :init s;
    },
    .createNodes = createNodes,
    .modifyOut = modifyOut,
    .initParams = initParams,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "swap_roi", @as(i32, 0));
}

pub fn modifyOut(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const input_sock = try api.getModSocket(pipe, mod, "input");
    var output_sock = try api.getModSocket(pipe, mod, "output");

    var out_roi = input_sock.roi orelse return error.ModuleROIMissing;
    const swap = try api.getParam(pipe, mod, "swap_roi", i32);
    if (swap != 0) {
        const tmp = out_roi.w;
        out_roi.w = out_roi.h;
        out_roi.h = tmp;
    }
    output_sock.roi = out_roi;
}

const shader_code: []const u8 =
    \\enable f16;
    \\@group(1) @binding(0) var input: texture_2d<f32>;
    \\@group(1) @binding(1) var output: texture_storage_2d<r16float, write>;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    \\    let coords = vec2<i32>(global_id.xy);
    \\    textureStore(output, coords, vec4<f32>(textureLoad(input, coords, 0).r, 0.0, 0.0, 1.0));
    \\}
;

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = .{ .wgsl = shader_code },
        .name = "swap-roi",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rggb16float,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rggb16float,
                .roi = null,
            };
            break :init s;
        },
    };
    const node = try api.addNodeDesc(pipe, mod, node_desc);
    try api.inheritSocket(pipe, mod, "input", node, "input");
    try api.inheritSocket(pipe, mod, "output", node, "output");
}