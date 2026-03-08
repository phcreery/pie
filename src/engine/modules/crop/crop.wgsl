enable f16;
struct Params {
    rotation_deg: f32,
};
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    cam_to_rec2020: mat3x3<f32>,
};

@group(0) @binding(0) var<storage, read_write> params:     Params;
@group(0) @binding(1) var<uniform>             img_params: ImgParams;
@group(1) @binding(0) var                      input:      texture_2d<f32>;
@group(1) @binding(1) var                      output:     texture_storage_2d<rgba16float, write>;


// Function to rotate a 2D vector
fn rotate2D(v: vec2<f32>, angle: f32) -> vec2<f32> {
    let s = sin(angle);
    let c = cos(angle);
    return vec2<f32>(
        v.x * c - v.y * s,
        v.x * s + v.y * c
    );
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var output_coords = vec2<i32>(global_id.xy);

    let input_dims    = textureDimensions(input);
    let output_dims   = textureDimensions(output);
    let center_input  = vec2<f32>(f32(input_dims.x)  / 2.0, f32(input_dims.y)  / 2.0);
    let center_output = vec2<f32>(f32(output_dims.x) / 2.0, f32(output_dims.y) / 2.0);

    // rotate about center of image by creating a vector from the center 
    // of the output image to the current output pixel
    var output_coords_f32 = vec2<f32>(output_coords);
    let output_vec     = output_coords_f32 - center_output;
    let rotation_rad   = radians(params.rotation_deg);
    let rotated_vec    = rotate2D(output_vec, -rotation_rad);
    let rotated_coords = rotated_vec + center_input;
    var input_coords   = vec2<i32>(
        i32(round(rotated_coords.x)),
        i32(round(rotated_coords.y)),
    );

    if (input_coords.x < 0 || input_coords.x >= i32(input_dims.x) || input_coords.y < 0 || input_coords.y >= i32(input_dims.y)) {
        // out of bounds, write black
        textureStore(output, output_coords, vec4<f32>(0.0, 0.0, 0.0, 1.0));
        return;
    }
    let px = textureLoad(input, input_coords, 0);
    textureStore(output, output_coords, vec4<f32>(px.r, px.g, px.b, px.a));
}
