enable f16;
struct ImgParams {
    black:  vec4<f32>,
    white:  vec4<f32>,
    white_balance: vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_from_cam:   mat3x3<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:  texture_2d<f32>;
@group(1) @binding(1) var           output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a));

    // NOTE: white balance should be applied before interpolation.
    let r_denom = max(1.0, img_params.white.r - img_params.black.r);
    let g_denom = max(1.0, img_params.white.g - img_params.black.g);
    let b_denom = max(1.0, img_params.white.b - img_params.black.b);
    let g2_denom = max(1.0, img_params.white.a - img_params.black.a);

    let wb_r = img_params.white_balance.r;
    let wb_g1 = img_params.white_balance.g;
    let wb_b = img_params.white_balance.b;
    let wb_g2 = img_params.white_balance.a;

    // Packed raw layout:
    // even rows: [R, G1, R, G1]
    // odd rows : [G2, B, G2, B]
    let is_even_y = (coords.y % 2) == 0;

    var values: vec4<f32>;
    if (is_even_y) {
        values = vec4<f32>(
            clamp(((pxf.r - img_params.black.r) / r_denom) * wb_r, 0.0, 1.0),
            clamp(((pxf.g - img_params.black.g) / g_denom) * wb_g1, 0.0, 1.0),
            clamp(((pxf.b - img_params.black.r) / r_denom) * wb_r, 0.0, 1.0),
            clamp(((pxf.a - img_params.black.g) / g_denom) * wb_g1, 0.0, 1.0),
        );
    } else {
        values = vec4<f32>(
            clamp(((pxf.r - img_params.black.a) / g2_denom) * wb_g2, 0.0, 1.0),
            clamp(((pxf.g - img_params.black.b) / b_denom) * wb_b, 0.0, 1.0),
            clamp(((pxf.b - img_params.black.a) / g2_denom) * wb_g2, 0.0, 1.0),
            clamp(((pxf.a - img_params.black.b) / b_denom) * wb_b, 0.0, 1.0),
        );
    }

    textureStore(output, coords, values);
}
