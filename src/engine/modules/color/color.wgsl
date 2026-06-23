enable f16;

struct Params {
    wb_temp: f32,
    wb_tint: f32,
};

struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_from_cam:   mat3x3<f32>,
};

@group(0) @binding(0) var<storage, read_write> params: Params;
@group(0) @binding(1) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:      texture_2d<f32>;
@group(1) @binding(1) var           output:     texture_storage_2d<rgba16float, write>;

fn mul3x3Rows(m: mat3x3<f32>, v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    );
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    
    let rgb_cam = vec3<f32>(px.r, px.g, px.b); // * relative_wb;

    let rgb_srgb_linear = mul3x3Rows(img_params.srgb_from_cam, rgb_cam);
    let out_px = vec4<f32>(rgb_srgb_linear, px.a);
    textureStore(output, coords, out_px);
}
