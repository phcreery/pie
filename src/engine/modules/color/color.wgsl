enable f16;
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    // cam_to_rec2020: mat3x3<f32>,
    cam_to_srgb:    mat3x3<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:      texture_2d<f32>;
@group(1) @binding(1) var           output:     texture_storage_2d<rgba16float, write>;
// helper: linear -> sRGB (must be top-level in WGSL)
fn linear_to_srgb(c: f32) -> f32 {
    if (c <= 0.0031308) {
        return c * 12.92;
    } else {
        return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }
}
fn linear_to_srgb_vec3(v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(linear_to_srgb(v.x), linear_to_srgb(v.y), linear_to_srgb(v.z));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let rgb_cam = vec3<f32>(px.r, px.g, px.b);

    // apply white balance (in the camera color space?) by multiplying the rgb values by the white balance coefficients
    let wb = vec3<f32>(
        img_params.white_balance.r,
        img_params.white_balance.g,
        img_params.white_balance.b
    );
    var rgb_cam_wb = rgb_cam * wb;
    // skip wb for now
    // var rgb_cam_wb = rgb_cam;
    
    // apply the cam_to_srgb matrix to convert from the camera color space to sRGB
    var rgb_rec2020 = vec3<f32>(
        img_params.cam_to_srgb[0][0] * rgb_cam_wb.r + img_params.cam_to_srgb[0][1] * rgb_cam_wb.g + img_params.cam_to_srgb[0][2] * rgb_cam_wb.b,
        img_params.cam_to_srgb[1][0] * rgb_cam_wb.r + img_params.cam_to_srgb[1][1] * rgb_cam_wb.g + img_params.cam_to_srgb[1][2] * rgb_cam_wb.b,
        img_params.cam_to_srgb[2][0] * rgb_cam_wb.r + img_params.cam_to_srgb[2][1] * rgb_cam_wb.g + img_params.cam_to_srgb[2][2] * rgb_cam_wb.b
    );

    // var rgb_srgb = linear_to_srgb_vec3(max(rgb_rec2020, vec3<f32>(0.0)));
    let out_px = vec4<f32>(rgb_rec2020, px.a);
    textureStore(output, coords, out_px);
}