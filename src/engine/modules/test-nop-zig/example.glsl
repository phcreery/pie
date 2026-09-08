#version 450
#extension GL_EXT_samplerless_texture_functions : enable
layout(set = 1, binding = 0) uniform texture2D inp;
layout(set = 1, binding = 1, rgba16f) uniform writeonly image2D outp;
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    vec4 pixel = texelFetch(inp, coords, 0);
    imageStore(outp, coords, pixel);
}