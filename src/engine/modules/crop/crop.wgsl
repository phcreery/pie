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

    let input_dims = textureDimensions(input);
    let iw = i32(input_dims.x);
    let ih = i32(input_dims.y);
    let center_input = vec2<f32>(f32(iw) / 2.0, f32(ih) / 2.0);
    let output_dims = textureDimensions(output);
    let ow = i32(output_dims.x);
    let oh = i32(output_dims.y);
    let center_output = vec2<f32>(f32(ow) / 2.0, f32(oh) / 2.0);
    
    var rotation_deg: f32 = 0.0;

    // orientation from image metadata (EXIF-style): 1 = normal, 3 = 180, 6 = 90 CW, 8 = 270 CW
    switch (img_params.orientation) {
        case 1: { /* normal */ }
        case 3: { rotation_deg = 180.0; } // 180
        case 6: { rotation_deg = 90.0; } // 90 CW
        case 8: { rotation_deg = 270.0; } // 270 CW
        default: { /* unknown, treat as normal */ }
    }

    // rotate about center of image by creating a vector from the center 
    // of the output image to the current output pixel
    var output_coords_f32 = vec2<f32>(output_coords);
    let output_vec     = output_coords_f32 - center_output;
    let rotation_rad   = radians(rotation_deg);
    let rotated_vec    = rotate2D(output_vec, -rotation_rad);
    let rotated_coords = rotated_vec + center_input;
    var input_coords   = vec2<i32>(
        i32(round(rotated_coords.x)),
        i32(round(rotated_coords.y)),
    );

    // 
    if (input_coords.x < 0 || input_coords.x >= iw || input_coords.y < 0 || input_coords.y >= ih) {
        // out of bounds, write black
        textureStore(output, output_coords, vec4<f32>(0.0, 0.0, 0.0, 1.0));
        return;
    }
    let px = textureLoad(input, input_coords, 0);
    textureStore(output, output_coords, vec4<f32>(px.r, px.g, px.b, px.a));
}
