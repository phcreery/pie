const std = @import("std");
const pie = @import("pie");

const Module = struct {
    // CONTENTS OF MODULE
    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn doubleMe(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let coords = vec2<i32>(global_id.xy);
        \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
        \\    pixel *= f32(2.0);
        \\    textureStore(output, coords, pixel);
        \\}
    ;
    pub fn create_nodes(pipe: *pie.engine.pipeline.Pipeline, mod: *pie.engine.pipeline.Module) !void {
        const node_desc = pie.engine.pipeline.NodeDesc{
            .shader_code = shader_code,
            .entry_point = "doubleMe",
            .run_size = mod.input_conn.?.roi,
            .input_conn = .{
                .name = "input",
                .type = .input,
                .format = .rgba16float,
                .roi = mod.input_conn.?.roi,
            },
            .output_conn = .{
                .name = "output",
                .type = .output,
                .format = .rgba16float,
                .roi = mod.output_conn.?.roi,
            },
        };
        pipe.addNodeDesc(node_desc) catch unreachable;
    }

    pub const module: pie.engine.pipeline.Module = pie.engine.pipeline.Module{
        .name = "Double Module",
        .enabled = true,
        // .param_ui = "",
        // .param_uniform = "",
        .input_conn = pie.engine.pipeline.Connector{
            .name = "input",
            .type = .input,
            .format = .rgba16float,
            .roi = null,
        },
        .output_conn = pie.engine.pipeline.Connector{
            .name = "output",
            .type = .output,
            .format = .rgba16float,
            .roi = null,
        },
        .create_nodes = create_nodes,
    };
};

test "simple module test" {
    const allocator = std.testing.allocator;
    var init_contents = std.mem.zeroes([4]f16);
    _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
    const roi = pie.engine.ROI{
        .size = .{
            .w = 1,
            .h = 1,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };

    var pipeline = pie.engine.pipeline.Pipeline.init(allocator) catch unreachable;
    defer pipeline.deinit();

    try pipeline.addModule(Module.module);

    const result = try pipeline.runWithSource(&init_contents, roi);

    // if (true) {
    //     return error.SkipZigTest;
    // }

    var expected_contents = std.mem.zeroes([256]f16);
    _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
