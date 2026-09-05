enable f16;
struct ImgParams {
    black:  vec4<f32>,
    white:  vec4<f32>,
    white_balance: vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_d65_from_cam:   mat3x3<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:  texture_2d<f32>;
@group(1) @binding(1) var           output: texture_storage_2d<r16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    // single-channel rggb mosaic: each texel is exactly one photosite
    let v = textureLoad(input, coords, 0).r;

    // bayer phase of this photosite:
    // (0,0) = R, (1,0) = G1, (0,1) = G2, (1,1) = B
    let phase_x = coords.x % 2;
    let phase_y = coords.y % 2;

    // pick the black/white per-channel values for this photosite's color
    var black: f32;
    var white: f32;
    if (phase_x == 0 && phase_y == 0) {
        black = img_params.black.r;
        white = img_params.white.r;
    } else if (phase_x == 1 && phase_y == 0) {
        black = img_params.black.g;
        white = img_params.white.g;
    } else if (phase_x == 0 && phase_y == 1) {
        black = img_params.black.a;
        white = img_params.white.a;
    } else {
        black = img_params.black.b;
        white = img_params.white.b;
    }

    // white balance + normalize to [0,1]
    let norm = clamp((v - black) / max(1.0, white - black), 0.0, 1.0);
    textureStore(output, coords, vec4<f32>(norm, 0.0, 0.0, 1.0));
}