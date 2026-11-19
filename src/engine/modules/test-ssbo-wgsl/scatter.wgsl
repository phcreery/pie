enable f16;

@group(1) @binding(0) var input: texture_2d<f32>;
@group(1) @binding(1) var<storage, read_write> tmp: array<f32>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let coords = vec2<i32>(gid.xy);
    let size = textureDimensions(input);
    tmp[0] = f32(size.x);
    tmp[1] = f32(size.y);
    let base = 2u + (gid.y * size.x + gid.x) * 4u;
    let px = textureLoad(input, coords, 0);
    tmp[base + 0u] = px.x;
    tmp[base + 1u] = px.y;
    tmp[base + 2u] = px.z;
    tmp[base + 3u] = px.w;
}
