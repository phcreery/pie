enable f16;
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    cam_to_rec2020: mat3x3<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:      texture_2d<f32>;
@group(1) @binding(1) var           output:     texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let rgb_cam = vec3<f32>(px.r, px.g, px.b);

    let wb = vec3<f32>(
        img_params.white_balance.r,
        img_params.white_balance.g,
        img_params.white_balance.b
    );
    let wb_max = max(max(wb.r, wb.g), wb.b);
    let wb_normalized = wb / vec3<f32>(wb_max, wb_max, wb_max);
    var rgb_cam_wb = rgb_cam * wb_normalized;
    
    // skipping camera to rec2020 conversion for now, as it is not always necessary and can be expensive. We can add it back in later if needed.
    var rgb_rec2020 = rgb_cam_wb;

    let out_px = vec4<f32>(rgb_rec2020, px.a);
    textureStore(output, coords, out_px);
}