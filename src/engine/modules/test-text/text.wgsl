enable f16;

const screen_tri = array(
    vec2f(-3.0, -1.0),   // bottom left
    vec2f( 1.0, -1.0),   // bottom right
    vec2f( 1.0,  3.0),   // top right
);
const font = array(
    0xebfbe7fcu,
    0xa89b21b4u,
    0xa93fb9fcu,
    0xaa1269a4u,
    0xebf3f9e4u
);
const max_number_length: u32 = 4;

fn get_sd_circle(pos: vec2<f32>, r: f32) -> f32 {
    return length(pos) - r;
}

fn get_view_coords(coords: vec2<f32>, screen_dims: vec2<f32>) -> vec2<f32>{
    return ((coords / screen_dims) * 2) - 1;
}

fn is_in_digit(frag_position: vec2<f32>, char: u32, position: vec2<u32>, scale: f32) -> bool {
    let offset = char * 3u;
    let rows = array(
        (font[0] >> (29 - offset)) & 0x07,
        (font[1] >> (29 - offset)) & 0x07,
        (font[2] >> (29 - offset)) & 0x07,
        (font[3] >> (29 - offset)) & 0x07,
        (font[4] >> (29 - offset)) & 0x07
    );

    let bump = -0.0001; //this make fractions like 3/3 fall under a whole number.
    let x = i32(floor(((frag_position.x - f32(position.x)) - bump) / scale));
    let y = i32(floor(((frag_position.y - f32(position.y)) - bump) / scale));

    if x > 2 || x < 0 { return false; }
    if y > 4 || y < 0 { return false; }

    return ((rows[y] >> (2 - u32(x))) & 0x01) == 1;
}

fn is_in_number(frag_position: vec2<f32>, digits: array<u32, max_number_length>, position: vec2<u32>, scale: f32) -> bool {
    var i: u32 = 0;
    var current_position = position.xy;

    loop {
        if i > max_number_length - 1 { return false; }
        let digit_size = u32(3 * scale);
        let spacing_size = u32(f32(i) * scale);
        if is_in_digit(frag_position, digits[i], vec2(current_position.x + (i * digit_size) + spacing_size, current_position.y), scale) {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn number_to_digits(value: f32) -> array<u32, max_number_length> {
    var digits = array<u32, max_number_length>();
    var num = value;

    if(num == 0){
        return digits;
    }

    var i: u32 = 0;
    loop{
        if num < 0 || i >= max_number_length { break; }
        digits[max_number_length - i - 1] = u32(num % 10);
        num = floor(num / 10);
        i = i + 1;
    }
    return digits;
}

// MAIN /////////////////////////////////////////////////

struct Params {
    value: f32,
};
@group(0) @binding(0) var<storage, read_write>  params: Params;
@group(1) @binding(0) var                       input:      texture_2d<f32>;
@group(1) @binding(1) var                       output:     texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    var coords = vec2<i32>(global_id.xy);

    if is_in_number(vec2<f32>(coords), number_to_digits(params.value), vec2(10, 200), 10.0) {
        textureStore(output, coords, vec4<f32>(1.0, 0.0, 0.0, 1.0));
        return;
    }

    let px = textureLoad(input, coords, 0);
    textureStore(output, coords, vec4<f32>(px.r, px.g, px.b, px.a));
}
