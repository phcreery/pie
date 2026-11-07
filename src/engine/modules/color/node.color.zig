//!   zig build-obj -target spirv32-vulkan -mcpu generic+v1_1 -ofmt=spirv -fno-llvm \
//!     -femit-bin=color.comp.spv \
//!     --dep shader --dep math --dep types -Mroot=src/engine/modules/color/node.color.zig \
//!     --dep math --dep types -Mshader=src/spirv/spirv.zig \
//!     -Mmath=src/math/root.zig -Mtypes=src/types/root.zig
//!   spirv-dis color.comp.spv | less

const shd = @import("shader");
const math = @import("math");
const ImgParams = @import("types").ImgParamsGpu;

const Vec3f32 = math.mat3.Vec3f32;
const Mat3f32 = math.mat3.Mat3f32;
const Vec4f32 = shd.Vec4f32;

const module_zon: shd.ModuleDesc = @import("module.zon");
const node_zon: shd.NodeDesc = @import("node.color.zon");

const Params = extern struct {
    // wb_temp: f32,
    // wb_tint: f32,
    // Camera white in linear Rec.2020.
    wb_coeff: [3]f32 align(16),
};

const params = shd.getParams(module_zon, Params);
const img_params = shd.getImgParams(module_zon, ImgParams);
const input_image = shd.getImageFromZon(node_zon, "input");
const output_image = shd.getImageFromZon(node_zon, "output");

inline fn cat16(rec2020_d65: Vec3f32, rec2020_src: Vec3f32, rec2020_dst: Vec3f32) Vec3f32 {
    // these are the CAT16 M^{-1} and M matrices.
    // we use the standalone adaptation as proposed in
    // Smet and Ma, "Some concerns regarding the CAT16 chromatic adaptation transform",
    // Color Res Appl. 2020;45:172–177.
    // these are XYZ to cone-like
    const M16 = Mat3f32.fromRows(.{
        .{ 0.401288, 0.650173, -0.051461 },
        .{ -0.250268, 1.204414, 0.045854 },
        .{ -0.002079, 0.048952, 0.953127 },
    });
    const M16i = Mat3f32.fromRows(.{
        .{ 1.86206786, -1.01125463, 0.14918677 },
        .{ 0.38752654, 0.62144744, -0.00897398 },
        .{ -0.01584150, -0.03412294, 1.04996444 },
    });

    const m16_xyz = M16.mul(math.matrices.xyz_from_rec2020);
    const cl_src = m16_xyz.mulVec(rec2020_src);
    const cl_dst = m16_xyz.mulVec(rec2020_dst);
    var cl = m16_xyz.mulVec(rec2020_d65);
    cl = cl * (cl_dst / cl_src);
    return math.matrices.rec2020_from_xyz_d65.mul(M16i).mulVec(cl);
}

inline fn decodeColour(rgb_cam: Vec3f32) Vec3f32 {
    const m = &img_params.rec2020_from_cam;
    return Mat3f32.fromRows(.{
        .{ m.c0.x, m.c0.y, m.c0.z },
        .{ m.c1.x, m.c1.y, m.c1.z },
        .{ m.c2.x, m.c2.y, m.c2.z },
    }).mulVec(rgb_cam);
}

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    const px = shd.imageFetch(input_image, coord);

    const rgb_cam = Vec3f32{ px[0], px[1], px[2] };

    // cam -> rgb
    var rgb_rec2020_linear = decodeColour(rgb_cam);

    // White balance.
    // `wb_coeff` is the camera white in linear Rec.2020. Green is 1.0.
    // CAT16 adapts this white to D65. A neutral pixel becomes (1, 1, 1).
    rgb_rec2020_linear = cat16(rgb_rec2020_linear, Vec3f32{
        params.wb_coeff[0],
        params.wb_coeff[1],
        params.wb_coeff[2],
    }, Vec3f32{ 1.0, 1.0, 1.0 });

    const out_px = Vec4f32{
        rgb_rec2020_linear[0],
        rgb_rec2020_linear[1],
        rgb_rec2020_linear[2],
        px[3],
    };
    shd.imageWrite(output_image, coord, out_px);
}
