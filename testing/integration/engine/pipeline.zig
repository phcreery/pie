const std = @import("std");
const pie = @import("pie");

const gpu = pie.engine.gpu;

const ModuleCreateTestData = struct {
    // CONTENTS OF MODULE

    const roi: pie.engine.ROI = .{
        .size = .{
            .w = 1,
            .h = 1,
        },
        .origin = .{
            .x = 0,
            .y = 0,
        },
    };

    pub fn modify_roi_out(pipe: *pie.engine.pipeline.Pipeline, mod: *pie.engine.pipeline.Module) !void {
        _ = pipe;
        std.log.info("Modifying ROI for Create Test Data module", .{});
        mod.output_conn.?.roi = roi;
    }

    pub fn read_source(
        pipe: *pie.engine.pipeline.Pipeline,
        mod: *pie.engine.pipeline.Module,
        allocator: *gpu.GPUAllocator,
    ) !void {
        _ = pipe;
        _ = mod;

        var init_contents = std.mem.zeroes([4]f16);
        _ = std.mem.copyForwards(f16, init_contents[0..4], &[_]f16{ 1.0, 2.0, 3.0, 4.0 });
        // mod.output_conn.?.roi = roi;
        allocator.upload(f16, &init_contents, .rgba16float, roi);
        // TODO: enqueue write to module connector of type source
    }

    pub const module: pie.engine.api.ModuleDesc = .{
        .name = "Create Test Data Module",
        .enabled = true,
        // .param_ui = "",
        // .param_uniform = "",
        .input_conn = null,
        .output_conn = .{
            .name = "output",
            .type = .source,
            .format = .rgba16float,
            .roi = null,
        },
        .init = null,
        .deinit = null,
        .read_source = read_source,
        .create_nodes = null,
        .modify_roi_out = null,
    };
};

const ModuleDoubleMe = struct {
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
        std.log.info("Creating nodes for DoubleMe module", .{});
        const node_desc: pie.engine.api.NodeDesc = .{
            .shader_code = shader_code,
            .entry_point = "doubleMe",
            .run_size = mod.output_conn.?.roi,
            .input_conn = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
                .roi = mod.input_conn.?.roi,
            },
            .output_conn = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = mod.output_conn.?.roi,
            },
        };
        var node = pipe.addNodeDesc(node_desc) catch unreachable;
        // TODO: connect module connectors to node connectors
        node.output_conn_handle = mod.output_conn_handle;
    }

    pub var module: pie.engine.api.ModuleDesc = .{
        .name = "Double Module",
        .enabled = true,
        // .param_ui = "",
        // .param_uniform = "",
        .input_conn = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        },
        .output_conn = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        },
        .init = null,
        .deinit = null,
        .read_source = null,
        .create_nodes = create_nodes,
        .modify_roi_out = null,
    };
};

test "simple module test" {
    const allocator = std.testing.allocator;
    var pipeline = pie.engine.pipeline.Pipeline.init(allocator) catch unreachable;
    defer pipeline.deinit();

    _ = try pipeline.addModule(ModuleCreateTestData.module);
    _ = try pipeline.addModule(ModuleDoubleMe.module);

    try pipeline.run();

    // var expected_contents = std.mem.zeroes([4]f16);
    // _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    // try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
