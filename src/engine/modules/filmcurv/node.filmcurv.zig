//!   zig build-obj -target spirv32-vulkan -mcpu generic+v1_1 -ofmt=spirv -fno-llvm \
//!     -femit-bin=filmcurv.comp.spv \
//!     --dep shader --dep math -Mroot=src/engine/modules/filmcurv/filmcurv.comp.zig \
//!     --dep math --dep types -Mshader=src/spirv/spirv.zig \
//!     -Mmath=src/math/root.zig -Mtypes=src/types/root.zig
//!   spirv-dis filmcurv.comp.spv | less

const shd = @import("shader");
const math = @import("math");

const color = math.color;
const Vec3f32 = math.mat3.Vec3f32;
const Vec4f32 = shd.Vec4f32;

const zon: shd.NodeDesc = @import("node.filmcurv.zon");

const Params = extern struct {
    brightness: f32,
    contrast: f32,
    bias: f32,
    colormode: i32,
};

const params = shd.getParams(Params);
const input_image = shd.getImageFromZon(zon, "input");
const output_image = shd.getImageFromZon(zon, "output");

const COLORMODE_AGX: i32 = 0;

/// Clamps for the curve parameters; `il` must stay positive for `log2` in
/// `color.powf`, `k` must stay positive for the Weibull shape.
const MIN_BRIGHTNESS: f32 = 5e-3;
const MIN_CONTRAST: f32 = 1e-4;

const ZERO: Vec3f32 = @splat(0.0);

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

pub inline fn weibullCdfVec3(x: Vec3f32, il: f32, k: f32) Vec3f32 {
    return .{
        weibullCdf(x[0], il, k),
        weibullCdf(x[1], il, k),
        weibullCdf(x[2], il, k),
    };
}

pub inline fn agxWeibull(rgb: Vec3f32, il: f32, k: f32) Vec3f32 {
    const inset = math.matrices.agx_inset.mulVec(rgb);
    const mix_percent = 0.4;
    const hsv0 = color.rgbToHsv(inset);
    const curved = weibullCdfVec3(inset, il, k);
    var hsv1 = color.rgbToHsv(curved);
    hsv1[0] = color.lerpChromaticityAngle(hsv0[0], hsv1[0], mix_percent);
    const recolored = color.hsvToRgb(hsv1);
    return @max(math.matrices.agx_inset_inv.mulVec(recolored), @as(Vec3f32, @splat(0.0)));
}

inline fn applyFilmCurve(rgb: Vec3f32) Vec3f32 {
    const il = @max(MIN_BRIGHTNESS, params.brightness);
    const k = @max(MIN_CONTRAST, params.contrast);
    const biased = @max(rgb + @as(Vec3f32, @splat(params.bias)), ZERO);

    if (params.colormode == COLORMODE_AGX) {
        return agxWeibull(biased, il, k);
    }
    return weibullCdfVec3(biased, il, k);
}

export fn main() callconv(shd.call_conv) void {
    const coord = shd.coord();
    const px = shd.imageFetch(input_image, coord);

    const rgb_srgb_linear = @max(Vec3f32{ px[0], px[1], px[2] }, ZERO);
    const rgb_rec2020_linear = color.srgbToRec2020(rgb_srgb_linear);
    const rgb_display_rec2020_linear = applyFilmCurve(rgb_rec2020_linear);
    const rgb_display_srgb_linear = @max(color.rec2020ToSrgb(rgb_display_rec2020_linear), ZERO);
    const rgb_display = color.linearToSrgbVec3(rgb_display_srgb_linear);

    shd.imageWrite(output_image, coord, Vec4f32{
        rgb_display[0],
        rgb_display[1],
        rgb_display[2],
        px[3],
    });
}
