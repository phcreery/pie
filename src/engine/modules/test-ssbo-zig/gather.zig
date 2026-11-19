// Zig SPIR-V shader. It reads one f32 per channel from a storage buffer. It
// writes the output image.

const shd = @import("shader");
const zon: shd.NodeDesc = @import("node.gather.zon");

const tmp = shd.getBufferFromZon(zon, "tmp");
const output_image = shd.getImageFromZon(zon, "output");

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    const width: u32 = @intFromFloat(shd.bufferFetch(tmp, 0));
    const base = 2 + (coord[1] *% width +% coord[0]) *% 4;

    const px = shd.math.Vec4.new(
        shd.bufferFetch(tmp, base + 0),
        shd.bufferFetch(tmp, base + 1),
        shd.bufferFetch(tmp, base + 2),
        shd.bufferFetch(tmp, base + 3),
    );
    shd.imageWrite(output_image, coord, px);
}
