enable f16;

@group(1) @binding(0) var<storage, read> tmp: array<f32>;
@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let coords = vec2<i32>(gid.xy);
    let width = u32(tmp[0]);
    let base = 2u + (gid.y * width + gid.x) * 4u;
    let px = vec4<f32>(tmp[base + 0u], tmp[base + 1u], tmp[base + 2u], tmp[base + 3u]);
    textureStore(output, coords, px);
}
