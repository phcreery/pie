//!   zig build-obj -target spirv32-vulkan -mcpu generic+v1_1 -ofmt=spirv -fno-llvm \
//!     -femit-bin=filmcurv.comp.spv \
//!     --dep shader --dep math -Mroot=src/engine/modules/filmcurv/filmcurv.comp.zig \
//!     --dep math --dep types -Mshader=src/spirv/spirv.zig \
//!     -Mmath=src/math/root.zig -Mtypes=src/types/root.zig
//!   spirv-dis filmcurv.comp.spv | less

const shd = @import("shader");
const math = @import("math");

const color = math.color;
const Vec3 = math.Vec3;

const module_zon: shd.ModuleDesc = @import("module.zon");
const node_zon: shd.NodeDesc = @import("node.filmcurv.zon");

const params = shd.getParams(module_zon);
const input_image = shd.getImageFromZon(node_zon, "input");
const output_image = shd.getImageFromZon(node_zon, "output");

/// Clamps for the curve parameters; `il` must stay positive for `log2` in
/// `color.powf`, `k` must stay positive for the Weibull shape.
const MIN_BRIGHTNESS: f32 = 5e-3;
const MIN_CONTRAST: f32 = 1e-4;

/// Weibull CDF, used as the per-channel film curve.
///
/// * `il`: 1/lambda, the scale parameter (0, inf)
/// * `k`: the shape parameter (0, inf)
pub inline fn weibullCdf(x: f32, il: f32, k: f32) f32 {
    return 1.0 - @exp(-math.powf(@max(x, math.EPSILON) * il, k));
}

test "weibullCdf is a monotonically increasing CDF on [0, 1]" {
    const testing = @import("std").testing;
    var previous: f32 = -1.0;
    var x: f32 = 0.0;
    while (x <= 8.0) : (x += 0.25) {
        const y = weibullCdf(x, 3.8, 1.3);
        try testing.expect(y >= previous);
        try testing.expect(y >= 0.0 and y <= 1.0);
        previous = y;
    }
}

pub inline fn weibullCdfVec3(x: Vec3, il: f32, k: f32) Vec3 {
    return Vec3.new(
        weibullCdf(x.x, il, k),
        weibullCdf(x.y, il, k),
        weibullCdf(x.z, il, k),
    );
}

/// Port of vkdt's `agx()`: inset, per-channel Weibull curve, hue mix in
/// OkLab, outset.
pub inline fn agxWeibull(rgb: Vec3, il: f32, k: f32) Vec3 {
    const inset = math.matrices.agx_inset.mulVec(rgb);
    const mix_percent = 0.4;
    const oklch0 = color.rec2020ToOklch(inset);
    const curved = weibullCdfVec3(inset, il, k);
    var oklch1 = color.rec2020ToOklch(curved);
    oklch1.x = color.lerpChromaticityAngle(oklch0.x, oklch1.x, mix_percent);
    const recolored = color.oklchToRec2020(oklch1);
    return math.matrices.agx_inset_inv.mulVec(recolored);
}

inline fn applyFilmCurve(rgb: Vec3) Vec3 {
    const il = @max(MIN_BRIGHTNESS, params.brightness);
    const k = @max(MIN_CONTRAST, params.contrast);
    const biased = Vec3.add(rgb, Vec3.all(params.bias));

    if (params.colormode == .agx) {
        return agxWeibull(biased, il, k);
    }
    return weibullCdfVec3(biased, il, k);
}

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    const px = shd.imageFetch(input_image, coord);

    const rgb_rec2020_linear = Vec3.new(px.x, px.y, px.z);
    const rgb_rec2020_linear_display = applyFilmCurve(rgb_rec2020_linear);

    // temporary conversion from Rec.2020 linear to sRGB for display purposes
    const rgb_srgb_linear_display = math.matrices.srgb_from_rec2020.mulVec(rgb_rec2020_linear_display);
    const rgb_srgb_display = color.linearToSrgbVec3(rgb_srgb_linear_display);

    shd.imageWrite(output_image, coord, math.Vec4.new(
        rgb_srgb_display.x,
        rgb_srgb_display.y,
        rgb_srgb_display.z,
        px.w,
    ));
}
