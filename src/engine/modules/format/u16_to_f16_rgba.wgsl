enable f16;

struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_d65_from_cam:   mat3x3<f32>,
};

// no params on this module, so img_params is group 0 binding 0
// (see pipeline.runNodesCreateBindings)
@group(0) @binding(0) var<uniform> img_params: ImgParams;
@group(1) @binding(0) var input:  texture_2d<u32>;
@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(i32(global_id.x), i32(global_id.y));
    let px = textureLoad(input, coords, 0);
    // 16-bit samples -> [0,1]; 1/65535 keeps the exact 8-bit values widened by
    // x*257 intact, and gives 16-bit sources full f16 precision.
    textureStore(output, coords, vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a)) / 65535.0);
}
