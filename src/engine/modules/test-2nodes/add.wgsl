enable f16;
struct Params {
    value:      i32,
};
@group(0) @binding(0) var<storage, read_write> params: Params;
@group(1) @binding(0) var                      input:  texture_2d<f32>;
@group(1) @binding(1) var                      output: texture_storage_2d<rgba16float, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    var pixel = vec4<f32>(textureLoad(input, coords, 0));
    pixel += f32(params.value);
    textureStore(output, coords, pixel);
}