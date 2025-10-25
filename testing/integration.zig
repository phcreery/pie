const std = @import("std");
const pie = @import("pie");

fn simpleCompute() !void {}
pub fn main() !void {
    std.log.info("Starting WebGPU compute test", .{});
    try simpleCompute();
    // TODO: test swapping buffers
}

test "simple compute test" {
    var engine = try pie.engine.Engine.init();
    defer engine.deinit();

    // https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/shader.wgsl
    const shader_code: []const u8 =
        \\enable f16;
        \\//requires readonly_and_readwrite_storage_textures;
        \\@group(0) @binding(0) var input:  texture_2d<f32>;
        \\@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
        \\@compute @workgroup_size(64)
        \\fn doubleMe(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let coords = vec2<i32>(global_id.xy);
        \\    //let color = textureLoad(input, coords).rgb;
        \\    //let new_color = color * 2.0;
        \\    //textureStore(output, coords, vec4<f16>(new_color, 1.0));
        \\
        \\    var pixel = vec4<f32>(textureLoad(input, coords, 0));
        \\    pixel *= f32(2.0);
        \\    textureStore(output, coords, pixel);
        \\}
    ;
    var shader_pipe = try engine.compileShader(shader_code, "doubleMe");
    defer shader_pipe.deinit();

    const init_contents = [_]f16{ 1, 2, 3, 4 };
    engine.upload(&init_contents);
    engine.enqueueUpload();
    engine.enqueueUpload();
    engine.enqueue(shader_pipe);
    engine.enqueueDownload();
    engine.run();

    const result = try engine.download();
    engine.deinit();

    var output = [_]f16{ 0, 0, 0, 0 };
    for (result, 0..) |value, i| {
        output[i] += value;
    }
    std.log.info("Compute shader output: {any}", .{output});

    const expected = [_]f16{ 2, 4, 6, 8 };
    try std.testing.expect(std.mem.eql(f16, expected[0..], result));
}

test "simple compute double buffer test" {
    if (true) {
        return error.SkipZigTest;
    }
    var engine = try pie.engine.Engine.init();
    defer engine.deinit();

    // https://github.com/gfx-rs/wgpu/blob/trunk/examples/standalone/01_hello_compute/src/shader.wgsl
    const shader_code: []const u8 =
        \\@group(0) @binding(0)
        \\var<storage, read> input: array<f32>;
        \\@group(0) @binding(1)
        \\var<storage, read_write> output: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn doubleMe(@builtin(global_invocation_id) global_id: vec3<u32>) {
        \\    let index = global_id.x;
        \\    let array_length = arrayLength(&input);
        \\    if (global_id.x >= array_length) {
        \\        return;
        \\    }
        \\    output[global_id.x] = input[global_id.x] * 2.0;
        \\}
    ;
    var shader_pipe = try engine.compileShader(shader_code, "doubleMe");
    defer shader_pipe.deinit();

    const init_contents = [_]f32{ 1, 2, 3, 4 };
    engine.upload(&init_contents);
    engine.enqueue(shader_pipe);
    engine.swapBuffers();
    engine.enqueue(shader_pipe);
    engine.enqueueDownload();
    engine.run();


    const result = try engine.download();
    engine.deinit();


    var output = [_]f32{ 0, 0, 0, 0 };
    for (result, 0..) |value, i| {
        output[i] += value;
    }
    std.log.info("Compute shader output: {any}", .{output});



    const expected = [_]f32{ 4, 8, 12, 16 };
    try std.testing.expect(std.mem.eql(f32, expected[0..], result));
}
