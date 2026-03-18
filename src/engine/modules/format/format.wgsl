enable f16;
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    cam_to_rec2020: mat3x3<f32>,
};
@group(0) @binding(0) var<uniform> img_params: ImgParams;
@group(1) @binding(0) var input:  texture_2d<u32>;
@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    var pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a)); // raw sensor max values
    // TODO: convert integer/raw values to float and normalize by white (per-channel)
    // var w = vec4<f32>(img_params.white);
    // avoid division by zero
    // if (w.x == 0.0) { w.x = 1.0; }
    // if (w.y == 0.0) { w.y = 1.0; }
    // if (w.z == 0.0) { w.z = 1.0; }
    // if (w.w == 0.0) { w.w = 1.0; }
    // pxf = pxf / w; // now in ~0..1 linear range
    textureStore(output, coords, pxf);
}