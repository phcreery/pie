// zig build-obj -freference-trace=6 ./src/engine/modules/test-nop-zig/nop.comp.zig -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2 -fno-llvm -femit-bin='./src/engine/modules/test-nop-zig/nop.comp.spv'
// spirv-link --target-env=spv1.1 ./src/engine/modules/test-nop-zig/nop.comp.spv -o ./src/engine/modules/test-nop-zig/nopopt.comp.spv
// diff -u --color <(spirv-dis src/engine/modules/test-nop-zig/nop.comp.spv) <(spirv-dis src/engine/modules/test-nop-zig/nopopt.comp.spv)

const shd = @import("shader");
const zon: shd.NodeDesc = @import("node.nop.zon");

const input_image = shd.getImageFromZon(zon, "input");
const output_image = shd.getImageFromZon(zon, "output");

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    var px = shd.imageFetch(input_image, coord);
    // px = px + @Vector(4, f32){ 1.0, 1.0, 1.0, 2.0 };
    px = px + @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    shd.imageWrite(output_image, coord, px);
}
