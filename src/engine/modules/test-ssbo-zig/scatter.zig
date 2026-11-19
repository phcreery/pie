// Zig SPIR-V shader. It reads the input image. It writes one f32 per channel
// to a storage buffer.

const shd = @import("shader");
const zon: shd.NodeDesc = @import("node.scatter.zon");

const input_image = shd.getImageFromZon(zon, "input");
const tmp = shd.getBufferFromZon(zon, "tmp");

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    const size = shd.imageSize(input_image);
    shd.bufferWrite(tmp, 0, @floatFromInt(size[0]));
    shd.bufferWrite(tmp, 1, @floatFromInt(size[1]));

    const base = 2 + (coord[1] *% size[0] +% coord[0]) *% 4;
    const px = shd.imageFetch(input_image, coord);
    shd.bufferWrite(tmp, base + 0, px.x);
    shd.bufferWrite(tmp, base + 1, px.y);
    shd.bufferWrite(tmp, base + 2, px.z);
    shd.bufferWrite(tmp, base + 3, px.w);
}
