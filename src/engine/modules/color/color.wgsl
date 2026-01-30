enable f16;
struct ImgParams {
    black:  vec4<f32>,
    white:  vec4<f32>,
    whitebalance: vec4<f32>,
    cam_to_rec2020: mat3x3<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:  texture_2d<f32>;
@group(1) @binding(1) var           output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    // rgb = params.cam_to_rec2020 * rgb;
    let rgb_xyz = vec3<f32>(px.r, px.g, px.b);
    let rgb_rec2020 = img_params.cam_to_rec2020 * rgb_xyz;
    let out_px = vec4<f32>(rgb_rec2020, px.a);
    textureStore(output, coords, out_px);
}