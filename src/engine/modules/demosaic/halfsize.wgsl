enable f16;
@group(1) @binding(0) var input:  texture_2d<f32>;
@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    // One output pixel per 2x2 bayer cell (half-res demosaic).
    // input is a single-channel rggb mosaic (one photosite per texel):
    //   (2x,   2y  ) = R
    //   (2x+1, 2y  ) = G1
    //   (2x,   2y+1) = G2
    //   (2x+1, 2y+1) = B
    let coords = vec2<i32>(global_id.xy);
    let ox = coords.x * 2;
    let oy = coords.y * 2;

    let r  = textureLoad(input, vec2<i32>(ox,     oy),     0).r;
    let g1 = textureLoad(input, vec2<i32>(ox + 1, oy),     0).r;
    let g2 = textureLoad(input, vec2<i32>(ox,     oy + 1), 0).r;
    let b  = textureLoad(input, vec2<i32>(ox + 1, oy + 1), 0).r;

    let g = (g1 + g2) / 2.0;
    textureStore(output, coords, vec4<f32>(r, g, b, 1.0));
}