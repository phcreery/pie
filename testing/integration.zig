const std = @import("std");
const pie = @import("pie");

fn simpleCompute() !void {}
pub fn main() !void {
    std.log.info("Starting WebGPU compute test", .{});
    try simpleCompute();
    // TODO: test swapping buffers
}

test "simple test" {
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
    const shader_module = try engine.compileShader(shader_code);
    defer shader_module.release();

    const init_contents = [_]f32{ 1, 2, 3, 4 };
    engine.writeData(&init_contents);
    engine.enqueue(shader_module, "doubleMe");
    engine.enqueueReadData();
    engine.run();

    const result = try engine.readData();
    std.log.info("Compute shader result: ", .{});
    // const output_size = init_contents.len;
    for (result) |value| {
        std.debug.print("{d} ", .{value});
    }
    std.debug.print("\n", .{});

    const expected = [_]f32{ 2, 4, 6, 8 };
    try std.testing.expect(std.mem.eql(f32, expected[0..], result));
}
