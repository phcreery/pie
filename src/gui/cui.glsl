// CUI renderer shader. Port of docs/rendering.md to sokol-shdc slang.
// One vertex format (64 bytes), six shading modes, premultiplied output.

@vs vs
layout(location=0) in vec2 a_pos;
layout(location=1) in vec2 a_uv;
layout(location=2) in vec2 a_local;
layout(location=3) in vec2 a_half;
layout(location=4) in vec4 a_radii;
layout(location=5) in vec2 a_params;   // border, mode
layout(location=6) in vec4 a_color;
layout(location=7) in vec4 a_bcolor;

layout(binding=0) uniform vs_params {
    vec2 viewport;   // framebuffer size in pixels
};

out vec2 v_uv;
out vec2 v_local;
flat out vec2 v_half;
flat out vec4 v_radii;
flat out vec2 v_params;
out vec4 v_color;
flat out vec4 v_bcolor;

void main() {
    v_uv = a_uv;
    v_local = a_local;
    v_half = a_half;
    v_radii = a_radii;
    v_params = a_params;
    v_color = a_color;
    v_bcolor = a_bcolor;
    gl_Position = vec4(a_pos.x / viewport.x * 2.0 - 1.0,
                       1.0 - a_pos.y / viewport.y * 2.0,
                       0.0, 1.0);
}
@end

@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec2 v_uv;
in vec2 v_local;
flat in vec2 v_half;
flat in vec4 v_radii;
flat in vec2 v_params;
in vec4 v_color;
flat in vec4 v_bcolor;
out vec4 frag_color;

float sd_rrect(vec2 p, vec2 b, vec4 r) {
    float rr = p.x < 0.0 ? (p.y < 0.0 ? r.x : r.w) : (p.y < 0.0 ? r.y : r.z);
    rr = min(rr, min(b.x, b.y));
    vec2 q = abs(p) - b + rr;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}

float erf_(float x) {
    float s = sign(x);
    x = abs(x);
    float t = 1.0 / (1.0 + 0.3275911 * x);
    return s * (1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
        - 0.284496736) * t + 0.254829592) * t * exp(-x * x));
}

float bayer8(vec2 p) {
    ivec2 q = ivec2(mod(floor(p), 8.0));
    int a = q.x ^ q.y;
    int y = q.y;
    int m = ((a & 1) << 5) | ((y & 1) << 4) | ((a & 2) << 2) |
            ((y & 2) << 1) | ((a & 4) >> 1) | ((y & 4) >> 2);
    return (float(m) + 0.5) / 64.0;
}

void main() {
    int mode = int(v_params.y + 0.5);
    vec4 c = v_color;

    if (mode == 4) {                       // solid
        frag_color = vec4(c.rgb * c.a, c.a);
        return;
    }
    if (mode == 0) {                       // text
        float a = c.a * texture(sampler2D(tex, smp), v_uv).r;
        frag_color = vec4(c.rgb * a, a);
        return;
    }

    float d = sd_rrect(v_local, v_half, v_radii);

    if (mode == 1) {                       // rounded rect with optional border
        float outer = clamp(0.5 - d, 0.0, 1.0);
        float inner = v_params.x > 0.0 ? clamp(0.5 - (d + v_params.x), 0.0, 1.0) : outer;
        float fa = c.a * inner;
        float ba = v_bcolor.a * (outer - inner);
        frag_color = vec4(c.rgb * fa + v_bcolor.rgb * ba, fa + ba);
        return;
    }
    if (mode == 2) {                       // shadow
        float a = c.a * 0.5 * (1.0 - erf_(d / (max(v_params.x, 0.01) * 1.41421356)));
        frag_color = vec4(c.rgb * a, a);
        return;
    }
    if (mode == 5) {                       // ordered dither
        float t = bayer8(v_uv);
        float k = t >= v_params.x && t < c.a
            ? v_bcolor.a * clamp(0.5 - d, 0.0, 1.0)
            : 0.0;
        frag_color = vec4(v_bcolor.rgb * k, k);
        return;
    }

    // image
    float k = c.a * clamp(0.5 - d, 0.0, 1.0);
    vec4 t = texture(sampler2D(tex, smp), v_uv);
    frag_color = vec4(t.rgb * t.a * c.rgb * k, t.a * k);
}
@end

@program cui vs fs
