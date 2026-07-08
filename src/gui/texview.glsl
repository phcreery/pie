@vs vs
layout(binding=0) uniform vs_params {
    vec2 scale;   // aspect-corrected base scale * user zoom
    vec2 offset;  // pan offset in NDC [-1..1]
};
const vec2 pos[4] = {
    vec2(-1.0, -1.0),
    vec2(+1.0, -1.0),
    vec2(-1.0, +1.0),
    vec2(+1.0, +1.0),
};
out vec2 uv;

void main() {
    vec2 p = pos[gl_VertexIndex];
    // Shrink/move the fullscreen quad so the image keeps its aspect ratio
    // (letterboxed inside the window) and can be panned/zoomed.
    gl_Position = vec4(p * scale + offset, 0.0, 1.0);
    // uv still spans the full [0,1] range of the *image*, independent of pan/zoom.
    uv = p * vec2(0.5, -0.5) + 0.5;
}
@end

@fs fs
in vec2 uv;
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
out vec4 frag_color;

void main() {
    frag_color = textureLod(sampler2D(tex, smp), uv, 0);
}
@end

@program texview vs fs
