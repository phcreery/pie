enable f16;
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
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

    // decode_color()
    // var rgb_rec2020 = img_params.cam_to_rec2020 * rgb_cam;
    var rgb_rec2020 = rgb_cam;

    // init new wb var
    var w0 = vec3<f32>(0.0, 0.0, 0.0);
    var wb = vec3<f32>(
        img_params.white_balance.r,
        img_params.white_balance.g,
        img_params.white_balance.b
    );
    // for(var j: i32 = 0; j < 3; j = j + 1) {
    //     for(var i: i32 = 0; i < 3; i = i + 1) {
    //         w0[j] += img_params.cam_to_rec2020[i][j] / wb[i];
    //     }
    // }
    // w0[0] /= w0[1]; w0[2] /= w0[1]; w0[1] = 1.0f;
    // wb[0] = wb[0] / w0[1];
    // wb[1] = 1.0;
    // wb[2] = wb[2] / w0[1];
    rgb_rec2020 = vec3<f32>(
        rgb_rec2020.r * wb[0],
        rgb_rec2020.g * wb[1],
        rgb_rec2020.b * wb[2]
    );


    let out_px = vec4<f32>(rgb_rec2020, px.a);
    textureStore(output, coords, out_px);
}