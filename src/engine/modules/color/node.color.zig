//!   zig build-obj -target spirv32-vulkan -mcpu generic+v1_1 -ofmt=spirv -fno-llvm \
//!     -femit-bin=color.comp.spv \
//!     --dep shader --dep math --dep types -Mroot=src/engine/modules/color/node.color.zig \
//!     --dep math --dep types -Mshader=src/spirv/spirv.zig \
//!     -Mmath=src/math/root.zig -Mtypes=src/types/root.zig
//!   spirv-dis color.comp.spv | grep CopyLogical   # must print nothing: naga rejects it
//!   spirv-dis color.comp.spv | less

const shd = @import("shader");
const math = @import("math");
const ImgParams = @import("types").ImgParamsGpu;

const Vec3 = math.Vec3;
const Mat3 = math.Mat3;

const module_zon: shd.ModuleDesc = @import("module.zon");
const node_zon: shd.NodeDesc = @import("node.color.zon");

const Params = extern struct {
    // wb_temp: f32,
    // wb_tint: f32,
    // White-balance gain in linear Rec.2020, green-normalized.
    wb_coeff: [3]f32 align(16),
};

const params = shd.getParams(module_zon, Params);
const img_params = shd.getImgParams(module_zon, ImgParams);
const input_image = shd.getImageFromZon(node_zon, "input");
const output_image = shd.getImageFromZon(node_zon, "output");

inline fn cat16(rec2020_d65: Vec3, rec2020_src: Vec3, rec2020_dst: Vec3) Vec3 {
    // these are the CAT16 M^{-1} and M matrices.
    // we use the standalone adaptation as proposed in
    // Smet and Ma, "Some concerns regarding the CAT16 chromatic adaptation transform",
    // Color Res Appl. 2020;45:172–177.
    // these are XYZ to cone-like
    const M16 = Mat3.fromArray(.{
        .{ 0.401288, 0.650173, -0.051461 },
        .{ -0.250268, 1.204414, 0.045854 },
        .{ -0.002079, 0.048952, 0.953127 },
    });
    const M16i = Mat3.fromArray(.{
        .{ 1.86206786, -1.01125463, 0.14918677 },
        .{ 0.38752654, 0.62144744, -0.00897398 },
        .{ -0.01584150, -0.03412294, 1.04996444 },
    });

    const m16_xyz = M16.mul(math.matrices.xyz_from_rec2020);
    const cl_src = m16_xyz.mulVec(rec2020_src);
    const cl_dst = m16_xyz.mulVec(rec2020_dst);
    var cl = m16_xyz.mulVec(rec2020_d65);
    cl = Vec3.mul(cl, Vec3.div(cl_dst, cl_src));
    return math.matrices.rec2020_from_xyz_d65.mul(M16i).mulVec(cl);
}

inline fn decodeColour(rgb_cam: Vec3) Vec3 {
    const m = &img_params.rec2020_from_cam;
    return Mat3.fromArray(.{
        .{ m.c0.x, m.c0.y, m.c0.z },
        .{ m.c1.x, m.c1.y, m.c1.z },
        .{ m.c2.x, m.c2.y, m.c2.z },
    }).mulVec(rgb_cam);
}

inline fn gainOrOne(v: Vec3) Vec3 {
    return Vec3.new(
        if (v.x > 1e-6) v.x else 1.0,
        if (v.y > 1e-6) v.y else 1.0,
        if (v.z > 1e-6) v.z else 1.0,
    );
}

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    const px = shd.imageFetch(input_image, coord);

    const rgb_cam = Vec3.new(px.x, px.y, px.z);

    // cam -> rgb
    var rgb_rec2020_linear = decodeColour(rgb_cam);

    // White balance.
    const wb_gain = gainOrOne(Vec3.fromArray(&params.wb_coeff));
    const wb_white = Vec3.div(Vec3.one, wb_gain);
    rgb_rec2020_linear = cat16(
        rgb_rec2020_linear,
        wb_white,
        Vec3.one,
    );

    // Output
    const out_px = math.Vec4.new(rgb_rec2020_linear.x, rgb_rec2020_linear.y, rgb_rec2020_linear.z, px.w);
    shd.imageWrite(output_image, coord, out_px);
}
