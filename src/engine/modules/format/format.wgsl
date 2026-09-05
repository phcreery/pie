enable f16;
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_d65_from_cam:   mat3x3<f32>,
};
@group(0) @binding(0) var<uniform> img_params: ImgParams;
@group(1) @binding(0) var input:  texture_2d<u32>;
@group(1) @binding(1) var output: texture_storage_2d<r16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    // single-channel rggb mosaic: each texel is one photosite
    let px = textureLoad(input, coords, 0);
    let v = f16(f32(px.r)); // raw sensor value stored as f16
    textureStore(output, coords, vec4<f32>(f32(v), 0.0, 0.0, 1.0));
}