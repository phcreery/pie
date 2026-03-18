enable f16;
struct ImgParams {
    black:  vec4<f32>,
    white:  vec4<f32>,
    white_balance: vec4<f32>,
    orientation:    i32,
    cam_to_rec2020: mat3x3<f32>,
};

@group(0) @binding(0) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:  texture_2d<f32>;
@group(1) @binding(1) var           output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a));

    // NOTE: white balance should be applied before interpolation (half and bilinear demosaics could handle non-balanced data, but others are not).
    let r = max(0, (pxf.r - img_params.black.r) / (img_params.white.r - img_params.black.r));
    let g = max(0, (pxf.g - img_params.black.g) / (img_params.white.g - img_params.black.g));
    let b = max(0, (pxf.b - img_params.black.b) / (img_params.white.b - img_params.black.b));
    let g2 = max(0, (pxf.a - img_params.black.a) / (img_params.white.a - img_params.black.a));

    // oh yea, we hove to do a workaround for the rggb packed layout
    // INPUT
    // libraw outputs the raw data as a 1D buffer, but we interpret it as a 2D texture
    // [ [(r g r g)] [ r g r g ] ...
    //   [ g b g b ] [(g b g b)] ...
    //   [ r g r g ] [ r g r g ] ...
    //   [ g b g b ] [ g b g b ] ... ]
    // DECODE
    // var values: vec4<f32>;
    // let is_even_y = (coords.y % 2) == 0;
    // if (is_even_y) {
    //     let rgrg = textureLoad(input, coords, 0);
    //     // subtract black and scale by white
    //     // R
    //     values.x = max(0, (rgrg.x - img_params.black.r) / (img_params.white.r - img_params.black.r));
    //     values.z = max(0, (rgrg.z - img_params.black.r) / (img_params.white.r - img_params.black.r));
    //     // G1
    //     values.y = max(0, (rgrg.y - img_params.black.g) / (img_params.white.g - img_params.black.g));
    //     values.w = max(0, (rgrg.w - img_params.black.g) / (img_params.white.g - img_params.black.g));
    // } else {
    //     let gbgb = textureLoad(input, coords, 0);
    //     // subtract black and scale by white
    //     // G2
    //     values.x = max(0, (gbgb.x - img_params.black.a) / (img_params.white.a - img_params.black.a));
    //     values.z = max(0, (gbgb.z - img_params.black.a) / (img_params.white.a - img_params.black.a));
    //     // B
    //     values.y = max(0, (gbgb.y - img_params.black.b) / (img_params.white.b - img_params.black.b));
    //     values.w = max(0, (gbgb.w - img_params.black.b) / (img_params.white.b - img_params.black.b));
    // }

    // actually, lets just average the black levels and the white levels and use that for all channels, since we are not doing a real denoise and just want to test the pipeline
    // let px = textureLoad(input, coords, 0);
    // let pxf = vec4<f32>(f32(px.r), f32(px.g), f32(px.b), f32(px.a));
    // let black_avg = (img_params.black.r + img_params.black.g + img_params.black.b + img_params.black.a) / 4.0;
    // let white_avg = (img_params.white.r + img_params.white.g + img_params.white.b + img_params.white.a) / 4.0;
    // let r = max(0, (pxf.r - black_avg) / (white_avg - black_avg));
    // let g = max(0, (pxf.g - black_avg) / (white_avg - black_avg));
    // let b = max(0, (pxf.b - black_avg) / (white_avg - black_avg));
    // let g2 = max(0, (pxf.a - black_avg) / (white_avg - black_avg));

    let values = vec4<f32>(r, g, b, g2);
    textureStore(output, coords, values);
}