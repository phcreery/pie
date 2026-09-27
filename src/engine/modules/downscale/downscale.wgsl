enable f16;
struct Params {
    max_edge: i32,
};
struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_d65_from_cam:   mat3x3<f32>,
};

// the module declares params, so group 0 binding 0 is the params storage
// buffer and binding 1 is the uniform img_params (see pipeline.runNodesCreateBindings)
@group(0) @binding(0) var<storage, read_write> params:     Params;
@group(0) @binding(1) var<uniform>             img_params: ImgParams;
@group(1) @binding(0) var                      input:      texture_2d<f32>;
@group(1) @binding(1) var                      output:     texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let out_dims = textureDimensions(output);
    let in_dims  = textureDimensions(input);

    let ox = global_id.x;
    let oy = global_id.y;
    if (ox >= out_dims.x || oy >= out_dims.y || out_dims.x == 0u || out_dims.y == 0u) {
        return;
    }

    // box filter: the input window covering this output pixel
    let x0 = ox * in_dims.x / out_dims.x;
    let x1 = max(x0 + 1u, (ox + 1u) * in_dims.x / out_dims.x);
    let y0 = oy * in_dims.y / out_dims.y;
    let y1 = max(y0 + 1u, (oy + 1u) * in_dims.y / out_dims.y);

    var acc = vec4<f32>(0.0, 0.0, 0.0, 0.0);
    var count = 0u;
    for (var y = y0; y < y1; y = y + 1u) {
        for (var x = x0; x < x1; x = x + 1u) {
            acc = acc + textureLoad(input, vec2<i32>(i32(x), i32(y)), 0);
            count = count + 1u;
        }
    }
    if (count == 0u) {
        return;
    }

    textureStore(output, vec2<i32>(i32(ox), i32(oy)), acc / f32(count));
}
