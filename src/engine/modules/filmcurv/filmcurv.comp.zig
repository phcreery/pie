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

const zon: shd.NodeDesc = @import("filmcurv.comp.zon");

const input_image = shd.imageFromZon(zon, "input");
const output_image = shd.imageFromZon(zon, "output");

const COLORMODE_AGX: i32 = 4;

/// Clamps for the curve parameters; `il` must stay positive for `log2` in
/// `color.powf`, `k` must stay positive for the Weibull shape.
const MIN_BRIGHTNESS: f32 = 5e-3;
const MIN_CONTRAST: f32 = 1e-4;

const ZERO: Vec3f32 = @splat(0.0);

/// Module params. Layout matches `Param.layoutTaggedUnion` for
/// (f32, f32, f32, i32): offsets 0/4/8/12, no padding.
const Params = extern struct {
    brightness: f32,
    contrast: f32,
    bias: f32,
    colormode: i32,
};

/// Parameters live in the module's storage buffer on group 0, binding 0.
const params: *addrspace(.storage_buffer) Params = @extern(*addrspace(.storage_buffer) Params, .{
    .name = "params",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

inline fn applyFilmCurve(rgb: Vec3f32) Vec3f32 {
    const il = @max(MIN_BRIGHTNESS, params.brightness);
    const k = @max(MIN_CONTRAST, params.contrast);
    const biased = @max(rgb + @as(Vec3f32, @splat(params.bias)), ZERO);

    if (params.colormode == COLORMODE_AGX) {
        return color.agxWeibull(biased, il, k);
    }
    return color.weibullCdfVec3(biased, il, k);
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
