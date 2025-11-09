const std = @import("std");
const pie = @import("pie");

const gpu = pie.engine.gpu;

const ModuleCreateTestData = struct {
    // CONTENTS OF MODULE

    const source = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
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

    pub fn modifyROIOut(pipe: *pie.engine.pipeline.Pipeline, mod: *pie.engine.pipeline.Module) !void {
        _ = pipe;
        mod.desc.output_sock.?.roi = roi;
    }

    pub fn readSource(
        pipe: *pie.engine.pipeline.Pipeline,
        mod: *pie.engine.pipeline.Module,
        allocator: *gpu.GPUAllocator,
    ) !void {
        _ = pipe;
        _ = mod;

        allocator.upload(f16, &source, .rgba16float, roi);
    }

    pub fn createNodes(pipe: *pie.engine.pipeline.Pipeline, mod: *pie.engine.pipeline.Module) !void {
        const output_sock = mod.getSocket("output") orelse unreachable;
        const node_desc: pie.engine.api.NodeDesc = .{
            .type = .source,
            .shader_code = "",
            .entry_point = "Test Data Source",
            .run_size = null,
            // .input_sock = null,
            // .output_sock = output_sock,
            .sockets = .{
                output_sock,
            },
        };
        _ = pipe.addNodeDesc(mod, node_desc) catch unreachable;
        // TODO: associate node connections
    }

    pub const module: pie.engine.api.ModuleDesc = .{
        .name = "Create Test Data Module",
        .type = .source,
        // .param_ui = "",
        // .param_uniform = "",
        // .input_sock = null,
        .output_sock = .{
            .name = "output",
            .type = .source,
            .format = .rgba16float,
            .roi = null,
        },
        // .sockets = &[_]pie.engine.api.SocketDesc{
        //     .{
        //         .name = "output",
        //         .type = .source,
        //         .format = .rgba16float,
        //         .roi = null,
        //     },
        // },
        .init = null,
        .deinit = null,
        .readSource = readSource,
        .createNodes = createNodes,
        .modifyROIOut = modifyROIOut,
    };
};

const ModuleDoubleIt = struct {
    // CONTENTS OF MODULE
    const shader_code: []const u8 =
        \\enable f16;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn doubleIt(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let coords = vec2<i32>(global_id.xy);
        \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
        \\    pixel *= f32(2.0);
        \\    textureStore(output, coords, pixel);
        \\}
    ;
    pub fn createNodes(pipe: *pie.engine.pipeline.Pipeline, mod: *pie.engine.pipeline.Module) !void {
        const output_sock = mod.getSocket("output") orelse unreachable;
        const input_sock = mod.getSocket("input") orelse unreachable;
        const node_desc: pie.engine.api.NodeDesc = .{
            .type = .compute,
            .shader_code = shader_code,
            .entry_point = "doubleIt",
            .run_size = output_sock.roi,
            // .input_sock = input_sock,
            // .output_sock = output_sock,
            .sockets = &[_]pie.engine.api.SocketDesc{
                input_sock,
                output_sock,
            },
        };
        _ = pipe.addNodeDesc(mod, node_desc) catch unreachable;
        // node.input_conn_handle = mod.input_conn_handle;
        // node.output_conn_handle = mod.output_conn_handle;
    }

    pub var module: pie.engine.api.ModuleDesc = .{
        .name = "Double It",
        .type = .compute,
        // .param_ui = "",
        // .param_uniform = "",
        .input_sock = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        },
        .output_sock = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        },
        .init = null,
        .deinit = null,
        .readSource = null,
        .createNodes = createNodes,
        .modifyROIOut = null,
    };
};

test "simple module test" {
    const allocator = std.testing.allocator;
    var gpu_instance = try pie.engine.gpu.GPU.init();
    defer gpu_instance.deinit();
    var pipeline = pie.engine.pipeline.Pipeline.init(allocator, &gpu_instance) catch unreachable;
    defer pipeline.deinit();

    _ = try pipeline.addModuleDesc(ModuleCreateTestData.module);
    _ = try pipeline.addModuleDesc(ModuleDoubleIt.module);

    try pipeline.run();

    // var expected_contents = std.mem.zeroes([4]f16);
    // _ = std.mem.copyForwards(f16, expected_contents[0..4], &[_]f16{ 2.0, 4.0, 6.0, 8.0 });
    // try std.testing.expectEqualSlices(f16, expected_contents[0..], result);
}
