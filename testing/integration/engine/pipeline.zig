const std = @import("std");
const pie = @import("pie");

const gpu = pie.engine.gpu;
const Pipeline = pie.engine.Pipeline;
const Module = pie.engine.Module;
const api = pie.engine.api;

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

    pub fn modifyROIOut(pipe: *Pipeline, mod: *Module) !void {
        _ = pipe;
        mod.desc.output_socket.?.roi = roi;
    }

    pub fn readSource(
        pipe: *api.Pipeline,
        mod: *api.Module,
        mapped: *anyopaque,
    ) !void {
        _ = pipe;
        _ = mod;

        const upload_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
        // const upload_buffer_slice = upload_buffer_ptr[0..(roi.size.w * roi.size.h * 4)];
        @memcpy(upload_buffer_ptr, &source);
    }

    pub fn createNodes(pipe: *Pipeline, mod: *Module) !void {
        const same_as_mod_output_sock = mod.getSocket("output") orelse unreachable;
        const node_desc: api.NodeDesc = .{
            .type = .source,
            .shader_code = "",
            .entry_point = "Test Data Source",
            .run_size = null,
            .sockets = init: {
                var s: api.Sockets = @splat(null);
                s[0] = same_as_mod_output_sock;
                break :init s;
            },
        };
        const node = try pipe.addNodeDesc(mod, node_desc);
        try pipe.copyConnector(mod, "output", node, "output");
    }

    pub const module: api.ModuleDesc = .{
        .name = "Create Test Data Module",
        .type = .source,
        // .param_ui = "",
        // .param_uniform = "",
        .output_socket = .{
            .name = "output",
            .type = .source,
            .format = .rgba16float,
            .roi = null,
        },
        .init = null,
        .deinit = null,
        .readSource = readSource,
        .writeSink = null,
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
    pub fn createNodes(pipe: *Pipeline, mod: *Module) !void {
        const mod_output_sock = mod.getSocket("output") orelse unreachable;
        const node_desc: api.NodeDesc = .{
            .type = .compute,
            .shader_code = shader_code,
            .entry_point = "doubleIt",
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
        const node = try pipe.addNodeDesc(mod, node_desc);
        try pipe.copyConnector(mod, "input", node, "input");
        try pipe.copyConnector(mod, "output", node, "output");
    }

    pub var module: pie.engine.api.ModuleDesc = .{
        .name = "Double It",
        .type = .compute,
        // .param_ui = "",
        // .param_uniform = "",
        .input_socket = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
            .roi = null,
        },
        .output_socket = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        },
        .init = null,
        .deinit = null,
        .readSource = null,
        .writeSink = null,
        .createNodes = createNodes,
        .modifyROIOut = null,
    };
};

const ModuleReadTestData = struct {
    // CONTENTS OF MODULE

    const expected = [_]f16{ 2.0, 4.0, 6.0, 8.0 };

    pub fn writeSink(
        pipe: *Pipeline,
        mod: *Module,
        mapped: *anyopaque,
    ) !void {
        _ = pipe;

        const roi = mod.getSocket("input").?.roi orelse unreachable;

        const download_buffer_ptr: [*]f16 = @ptrCast(@alignCast(mapped));
        const download_buffer_slice = download_buffer_ptr[0..(roi.size.w * roi.size.h * 4)];
        std.log.info("Sink buffer contents: {any}", .{download_buffer_slice});
        try std.testing.expectEqualSlices(f16, &expected, download_buffer_slice);
    }

    pub fn createNodes(pipe: *Pipeline, mod: *Module) !void {
        const same_as_mod_output_sock = mod.getSocket("input") orelse unreachable;
        const node_desc: api.NodeDesc = .{
            .type = .sink,
            .shader_code = "",
            .entry_point = "Test Data Sink",
            .run_size = null,
            .sockets = init: {
                var s: api.Sockets = @splat(null);
                s[0] = same_as_mod_output_sock;
                break :init s;
            },
        };
        const node = try pipe.addNodeDesc(mod, node_desc);
        try pipe.copyConnector(mod, "input", node, "input");
    }

    pub const module: api.ModuleDesc = .{
        .name = "Read Test Data Module",
        .type = .sink,
        // .param_ui = "",
        // .param_uniform = "",
        // .input_sock = null,
        .input_socket = .{
            .name = "input",
            .type = .sink,
            .format = .rgba16float,
            .roi = null,
        },
        .init = null,
        .deinit = null,
        .readSource = null,
        .writeSink = writeSink,
        .createNodes = createNodes,
        .modifyROIOut = null,
    };
};

test "simple module test" {
    const allocator = std.testing.allocator;
    var gpu_instance = try gpu.GPU.init();
    defer gpu_instance.deinit();
    var pipeline = Pipeline.init(allocator, &gpu_instance) catch unreachable;
    defer pipeline.deinit();

    // _ = try pipeline.addModuleDesc(ModuleCreateTestData.module);
    // _ = try pipeline.addModuleDesc(ModuleDoubleIt.module);
    // _ = try pipeline.addModuleDesc(ModuleReadTestData.module);

    _ = try pipeline.addModuleDesc(pie.engine.modules.test_i_1234.module);
    _ = try pipeline.addModuleDesc(pie.engine.modules.test_double.module);
    _ = try pipeline.addModuleDesc(pie.engine.modules.test_o_2468.module);

    try pipeline.run();
}
