enable f16;

const COLORMODE_AGX: i32 = 4;
const EPSILON: f32 = 1e-7;

struct Params {
    brightness: f32,
    contrast: f32,
    bias: f32,
    colormode: i32,
};

struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_from_cam:   mat3x3<f32>,
};

@group(0) @binding(0) var<storage, read_write> params: Params;
@group(0) @binding(1) var<uniform> img_params: ImgParams;
@group(1) @binding(0) var input: texture_2d<f32>;
@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;

fn linear_to_srgb(c: f32) -> f32 {
    if (c <= 0.0031308) {
        return c * 12.92;
    }
    return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

fn linear_to_srgb_vec3(v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        linear_to_srgb(v.x),
        linear_to_srgb(v.y),
        linear_to_srgb(v.z),
    );
}

fn mul3x3_rows(r0: vec3<f32>, r1: vec3<f32>, r2: vec3<f32>, v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(dot(r0, v), dot(r1, v), dot(r2, v));
}

fn linear_srgb_to_rec2020(rgb: vec3<f32>) -> vec3<f32> {
    return mul3x3_rows(
        vec3<f32>(0.6274083694, 0.3292853862, 0.0433133745),
        vec3<f32>(0.0690961995, 0.9195258911, 0.0113621363),
        vec3<f32>(0.0163938775, 0.0880264019, 0.8957284939),
        rgb,
    );
}

fn linear_rec2020_to_srgb(rgb: vec3<f32>) -> vec3<f32> {
    return mul3x3_rows(
        vec3<f32>(1.6604791628, -0.5876504078, -0.0728390268),
        vec3<f32>(-0.1245495865, 1.1329177667, -0.0083481806),
        vec3<f32>(-0.0181506339, -0.1005804845, 1.1185632490),
        rgb,
    );
}

fn lerp_chromaticity_angle(h1: f32, h2: f32, t: f32) -> f32 {
    var h2m = h2;
    let delta = h2 - h1;
    if (delta > 0.5) {
        h2m = h2 - 1.0;
    } else if (delta < -0.5) {
        h2m = h2 + 1.0;
    }
    return fract(h1 + t * (h2m - h1));
}

fn rgb2hsv(c: vec3<f32>) -> vec3<f32> {
    let maxc = max(c.r, max(c.g, c.b));
    let minc = min(c.r, min(c.g, c.b));
    let delta = maxc - minc;

    var h: f32 = 0.0;
    if (delta > EPSILON) {
        if (maxc == c.r) {
            h = (c.g - c.b) / delta;
            if (c.g < c.b) {
                h += 6.0;
            }
        } else if (maxc == c.g) {
            h = ((c.b - c.r) / delta) + 2.0;
        } else {
            h = ((c.r - c.g) / delta) + 4.0;
        }
        h /= 6.0;
    }

    var s: f32 = 0.0;
    if (maxc > EPSILON) {
        s = delta / maxc;
    }
    return vec3<f32>(h, s, maxc);
}

fn hsv2rgb(c: vec3<f32>) -> vec3<f32> {
    let h = fract(c.x) * 6.0;
    let s = c.y;
    let v = c.z;
    let i = i32(floor(h));
    let f = h - floor(h);
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));

    switch i {
        case 0: { return vec3<f32>(v, t, p); }
        case 1: { return vec3<f32>(q, v, p); }
        case 2: { return vec3<f32>(p, v, t); }
        case 3: { return vec3<f32>(p, q, v); }
        case 4: { return vec3<f32>(t, p, v); }
        default: { return vec3<f32>(v, p, q); }
    }
}

fn weibull_cdf_scalar(x: f32, il: f32, k: f32) -> f32 {
    return 1.0 - exp(-pow(max(x, EPSILON) * il, k));
}

fn weibull_cdf_vec3(x: vec3<f32>, il: f32, k: f32) -> vec3<f32> {
    return vec3<f32>(
        weibull_cdf_scalar(x.x, il, k),
        weibull_cdf_scalar(x.y, il, k),
        weibull_cdf_scalar(x.z, il, k),
    );
}

fn agx_weibull(rgb: vec3<f32>, il: f32, k: f32) -> vec3<f32> {
    let agx_mat = array<vec3<f32>, 3>(
        vec3<f32>(0.8566271533, 0.1373189729, 0.1118982130),
        vec3<f32>(0.0951212405, 0.7612419906, 0.0767994186),
        vec3<f32>(0.0482516061, 0.1014390365, 0.8113023684),
    );
    let agx_mat_inv = array<vec3<f32>, 3>(
        vec3<f32>(1.1271005818, -0.1413297635, -0.1413297635),
        vec3<f32>(-0.1106066431, 1.1578237022, -0.1106066431),
        vec3<f32>(-0.0164939387, -0.0164939387, 1.2519364066),
    );

    let inset = mul3x3_rows(agx_mat[0], agx_mat[1], agx_mat[2], rgb);
    let mix_percent = 0.4;
    let hsv0 = rgb2hsv(inset);
    let curved = weibull_cdf_vec3(inset, il, k);
    var hsv1 = rgb2hsv(curved);
    hsv1.x = lerp_chromaticity_angle(hsv0.x, hsv1.x, mix_percent);
    let recolored = hsv2rgb(hsv1);
    return max(mul3x3_rows(agx_mat_inv[0], agx_mat_inv[1], agx_mat_inv[2], recolored), vec3<f32>(0.0));
}

fn apply_film_curve(rgb: vec3<f32>) -> vec3<f32> {
    let il = max(5e-3, params.brightness);
    let k = max(1e-4, params.contrast);
    let biased = max(rgb + vec3<f32>(params.bias), vec3<f32>(0.0));

    if (params.colormode == COLORMODE_AGX) {
        return agx_weibull(biased, il, k);
    }
    return weibull_cdf_vec3(biased, il, k);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    _ = img_params;

    let coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let rgb_srgb_linear = max(px.rgb, vec3<f32>(0.0));
    let rgb_rec2020_linear = linear_srgb_to_rec2020(rgb_srgb_linear);
    let rgb_display_rec2020_linear = apply_film_curve(rgb_rec2020_linear);
    let rgb_display_srgb_linear = max(linear_rec2020_to_srgb(rgb_display_rec2020_linear), vec3<f32>(0.0));
    let rgb_display = linear_to_srgb_vec3(rgb_display_srgb_linear);
    textureStore(output, coords, vec4<f32>(rgb_display, px.a));
}
