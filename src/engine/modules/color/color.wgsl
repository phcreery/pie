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

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let rgb_cam = vec3<f32>(px.r, px.g, px.b);

    // white balance is applied in the raw domain before demosaic (see denoise/noop.wgsl).
    // apply the cam_to_srgb matrix to convert from camera space to linear sRGB
    let rgb_srgb_linear = vec3<f32>(
        img_params.cam_to_srgb[0][0] * rgb_cam.r + img_params.cam_to_srgb[0][1] * rgb_cam.g + img_params.cam_to_srgb[0][2] * rgb_cam.b,
        img_params.cam_to_srgb[1][0] * rgb_cam.r + img_params.cam_to_srgb[1][1] * rgb_cam.g + img_params.cam_to_srgb[1][2] * rgb_cam.b,
        img_params.cam_to_srgb[2][0] * rgb_cam.r + img_params.cam_to_srgb[2][1] * rgb_cam.g + img_params.cam_to_srgb[2][2] * rgb_cam.b
    );

    let out_px = vec4<f32>(rgb_srgb_linear, px.a);
    textureStore(output, coords, out_px);
}