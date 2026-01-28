enable f16;
struct ImgParams {
    black:  vec4<f32>,
    white:  vec4<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:  texture_2d<f32>;
@group(1) @binding(1) var           output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a));
    // col = max(vec3(0), (col - push.black.rgb)/(push.white.rgb - push.black.rgb));
    let r = max(0, (pxf.r - img_params.black.r) / (img_params.white.r - img_params.black.r));
    let g = max(0, (pxf.g - img_params.black.g) / (img_params.white.g - img_params.black.g));
    let b = max(0, (pxf.b - img_params.black.b) / (img_params.white.b - img_params.black.b));
    let g2 = max(0, (pxf.a - img_params.black.a) / (img_params.white.a - img_params.black.a));
    textureStore(output, coords, vec4<f32>(r, g, b, g2));
}