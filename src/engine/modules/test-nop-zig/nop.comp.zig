// zig build-obj -freference-trace=6 ./src/engine/modules/test-nop-zig/nop.comp.zig -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2 -fno-llvm -femit-bin='./src/engine/modules/test-nop-zig/nop.comp.spv'
// spirv-link --target-env=spv1.1 ./src/engine/modules/test-nop-zig/nop.comp.spv -o ./src/engine/modules/test-nop-zig/nopopt.comp.spv
// diff -u --color <(spirv-dis src/engine/modules/test-nop-zig/nop.comp.spv) <(spirv-dis src/engine/modules/test-nop-zig/nopopt.comp.spv)

const spirv = @import("spirv");
const zon = @import("nop.comp.zon");

// const input_image = @extern(*addrspace(.constant) const spirv.InputImage, .{
//     .name = "input",
//     .decoration = .{ .descriptor = .{ .set = 1, .binding = 0 } },
// });

const InputImage2 = spirv.Image(@import("nop.comp.zon"), "input");
const input_image = spirv.imageFromZon(InputImage2, @import("nop.comp.zon"), "input");

const output_image = @extern(*addrspace(.constant) const spirv.OutputImage, .{
    .name = "output",
    .decoration = .{ .descriptor = .{ .set = 1, .binding = 1 } },
});

export fn main() callconv(spirv.call_conv) void {
    const coord = @as(spirv.Vec2u32, .{ spirv.global_invocation_id[0], spirv.global_invocation_id[1] });
    var pix = spirv.imageFetch(@TypeOf(input_image), input_image, coord);
    // pix = pix + @Vector(4, f32){ 1.0, 1.0, 1.0, 1.0 };
    pix = pix + @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    spirv.imageWrite(output_image, coord, pix);
}
