enable f16;

const DEFAULT_WB_TEMP: f32 = 5500.0;
const DEFAULT_WB_TINT: f32 = 0.0;
const EPSILON: f32 = 1e-6;

struct Params {
    wb_temp: f32,
    wb_tint: f32,
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
@group(0) @binding(1) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:      texture_2d<f32>;
@group(1) @binding(1) var           output:     texture_storage_2d<rgba16float, write>;

fn safeDenom(v: f32) -> f32 {
    if (abs(v) < EPSILON) {
        return select(-EPSILON, EPSILON, v >= 0.0);
    }
    return v;
}

fn cctToXy(cct_in: f32) -> vec2<f32> {
    let cct = clamp(cct_in, 1667.0, 25000.0);
    let cct2 = cct * cct;
    let cct3 = cct2 * cct;
    let inv_cct3 = 1e9 / cct3;
    let inv_cct2 = 1e6 / cct2;
    let inv_cct = 1e3 / cct;

    let x = select(
        -3.0258469 * inv_cct3 + 2.1070379 * inv_cct2 + 0.2226347 * inv_cct + 0.240390,
        -0.2661239 * inv_cct3 - 0.2343589 * inv_cct2 + 0.8776956 * inv_cct + 0.179910,
        cct <= 4000.0,
    );

    let y = select(
        3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483,
        select(
            -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867,
            -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683,
            cct <= 2222.0,
        ),
        cct <= 4000.0,
    );

    return vec2<f32>(x, y);
}

fn xyToUv(xy: vec2<f32>) -> vec2<f32> {
    let x = xy.x;
    let y = xy.y;
    let denom = safeDenom(-2.0 * x + 12.0 * y + 3.0);
    return vec2<f32>(4.0 * x / denom, 9.0 * y / denom);
}

fn uvToXy(uv: vec2<f32>) -> vec2<f32> {
    let u = uv.x;
    let v = uv.y;
    let denom = safeDenom(6.0 * u - 16.0 * v + 12.0);
    return vec2<f32>(9.0 * u / denom, 4.0 * v / denom);
}

fn sanitizeChromaticity(xy_in: vec2<f32>) -> vec2<f32> {
    var x = clamp(xy_in.x, 1e-4, 0.9998);
    var y = clamp(xy_in.y, 1e-4, 0.9998);
    let sum = x + y;
    if (sum >= 0.9998) {
        let scale = 0.9998 / sum;
        x *= scale;
        y *= scale;
    }
    return vec2<f32>(x, y);
}

fn locusNormalAtTemp(temp_in: f32) -> vec2<f32> {
    let temp = clamp(temp_in, 1667.0, 25000.0);
    let delta = max(10.0, temp * 0.0025);
    let uv_lo = xyToUv(cctToXy(temp - delta));
    let uv_hi = xyToUv(cctToXy(temp + delta));
    let tangent = uv_hi - uv_lo;
    let len = length(tangent);
    if (len <= EPSILON) {
        return vec2<f32>(0.0, 1.0);
    }
    return vec2<f32>(-tangent.y / len, tangent.x / len);
}

fn mul3x3Rows(m: mat3x3<f32>, v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    );
}

fn computeWhiteBalanceFromTempTint(temp: f32, tint: f32) -> vec3<f32> {
    let xy0 = cctToXy(temp);
    let uv0 = xyToUv(xy0);
    let tint_scale = 5e-5;
    let n = locusNormalAtTemp(temp);
    let uv = uv0 + tint_scale * tint * n;
    let xy = sanitizeChromaticity(uvToXy(uv));
    let X = xy.x / max(xy.y, EPSILON);
    let Y = 1.0;
    let Z = (1.0 - xy.x - xy.y) / max(xy.y, EPSILON);

    let m = img_params.xyz_from_cam;
    let a = m[0][0]; let b = m[0][1]; let c = m[0][2];
    let d = m[1][0]; let e = m[1][1]; let f = m[1][2];
    let g = m[2][0]; let h = m[2][1]; let i = m[2][2];

    let A =  e * i - f * h;
    let B = -(d * i - f * g);
    let C =  d * h - e * g;
    let D = -(b * i - c * h);
    let E =  a * i - c * g;
    let F = -(a * h - b * g);
    let G =  b * f - c * e;
    let H = -(a * f - c * d);
    let I =  a * e - b * d;

    let det = safeDenom(a * A + b * B + c * C);
    let xyz = vec3<f32>(X, Y, Z);
    let rgb = max(vec3<f32>(
        (A * xyz.x + D * xyz.y + G * xyz.z) / det,
        (B * xyz.x + E * xyz.y + H * xyz.z) / det,
        (C * xyz.x + F * xyz.y + I * xyz.z) / det,
    ), vec3<f32>(EPSILON));
    let green = max(rgb.g, EPSILON);
    return vec3<f32>(green / rgb.r, 1.0, green / rgb.b);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);

    // The raw-domain as-shot WB has already been applied upstream.
    // Apply temp/tint here as a post-demosaic relative camera-space correction.
    let neutral_wb = computeWhiteBalanceFromTempTint(DEFAULT_WB_TEMP, DEFAULT_WB_TINT);
    let target_wb = computeWhiteBalanceFromTempTint(params.wb_temp, params.wb_tint);
    let relative_wb = clamp(target_wb / neutral_wb, vec3<f32>(1e-4), vec3<f32>(64.0));
    let rgb_cam = vec3<f32>(px.r, px.g, px.b) * relative_wb;

    let rgb_srgb_linear = mul3x3Rows(img_params.srgb_from_cam, rgb_cam);
    let out_px = vec4<f32>(rgb_srgb_linear, px.a);
    textureStore(output, coords, out_px);
}
