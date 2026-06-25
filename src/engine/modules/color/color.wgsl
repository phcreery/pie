enable f16;

struct Params {
    wb_temp: f32,
    wb_tint: f32,
    wb_coeff: vec4<f32>,
};

struct ImgParams {
    black:          vec4<f32>,
    white:          vec4<f32>,
    white_balance:  vec4<f32>,
    orientation:    i32,
    srgb_from_cam:  mat3x3<f32>,
    xyz_d65_from_cam:   mat3x3<f32>,
};

@group(0) @binding(0) var<storage, read_write> params: Params;
@group(0) @binding(1) var<uniform>  img_params: ImgParams;
@group(1) @binding(0) var           input:      texture_2d<f32>;
@group(1) @binding(1) var           output:     texture_storage_2d<rgba16float, write>;

// TODO: put in common library for reuse in other modules. 
// This is a simple matrix-vector multiplication
fn mul3x3Rows(m: mat3x3<f32>, v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    );
}

// chromatic adaptation transform matrices, CAT16 M and inverse
// Smet and Ma, "Some concerns regarding the CAT16 chromatic adaptation transform",
// Color Res Appl. 2020;45:172–177.
// M: XYZ to cone-like
// #define matrix_cat16_Mi makemat(1.86206786, -1.01125463,  0.14918677, 0.38752654,  0.62144744, -0.00897398, -0.01584150, -0.03412294,  1.04996444)
// #define matrix_cat16_M  makemat(0.401288, 0.650173, -0.051461, -0.250268, 1.204414,  0.045854, -0.002079, 0.048952,  0.953127)

// XYZ
// #define matrix_rec2020_to_xyz makemat(0.636958048301290991, 0.144616903586208406, 0.168880975164172054, 0.26270021201126692, 0.677998071518871148, 0.0593017164698619384, 4.9999999999999999e-17, 0.0280726930490874452, 1.06098505771079066)
// #define matrix_xyz_to_rec2020 makemat(1.71665119, -0.35567078, -0.25336628, -0.66668435,  1.61648124,  0.01576855, 0.01763986, -0.04277061, 0.94210312)

// Rec709 to XYZ D65
// #define matrix_rec709_to_xyz makemat(0.412390799265959229, 0.357584339383878125, 0.180480788401834347, 0.212639005871510217, 0.71516867876775625, 0.0721923153607337414, 0.0193308187155918181, 0.119194779794626018, 0.950532152249661033)
// XYZ D65 to Rec709
// #define matrix_xyz_to_rec709 makemat(3.24096994190452348, -1.53738317757009435, -0.498610760293003552, -0.969243636280879506, 1.87596750150771996, 0.0415550574071755843, 0.0556300796969936354, -0.20397695888897649, 1.05697151424287816)



fn cat16(rec2020_d65: vec3<f32>, rec2020_src: vec3<f32>, rec2020_dst: vec3<f32>) -> vec3<f32> {
    // these are the CAT16 M^{-1} and M matrices.
    // we use the standalone adaptation as proposed in
    // Smet and Ma, "Some concerns regarding the CAT16 chromatic adaptation transform",
    // Color Res Appl. 2020;45:172–177.
    // these are XYZ to cone-like
    let M16 = transpose(mat3x3<f32>(
        vec3<f32>( 0.401288,  0.650173, -0.051461),
        vec3<f32>(-0.250268,  1.204414,  0.045854),
        vec3<f32>(-0.002079,  0.048952,  0.953127)
    ));
    let M16i = transpose(mat3x3<f32>(
        vec3<f32>( 1.86206786, -1.01125463,  0.14918677),
        vec3<f32>( 0.38752654,  0.62144744, -0.00897398),
        vec3<f32>(-0.01584150, -0.03412294,  1.04996444)
    ));
    // let rec2020_to_xyz = (mat3x3<f32>(
    //     vec3<f32>(0.636958048301290991, 0.144616903586208406, 0.168880975164172054),
    //     vec3<f32>(0.26270021201126692, 0.677998071518871148, 0.0593017164698619384),
    //     vec3<f32>(4.9999999999999999e-17, 0.0280726930490874452, 1.06098505771079066)
    // ));
    // let xyz_to_rec2020 = (mat3x3<f32>(
    //     vec3<f32>(1.71665119, -0.35567078, -0.25336628),
    //     vec3<f32>(-0.66668435,  1.61648124,  0.01576855),
    //     vec3<f32>(0.01763986, -0.04277061, 0.94210312)
    // ));
    let xyz_to_rec709 = transpose(mat3x3<f32>(
        vec3<f32>(3.24096994190452348, -1.53738317757009435, -0.498610760293003552),
        vec3<f32>(-0.969243636280879506, 1.87596750150771996, 0.0415550574071755843),
        vec3<f32>(0.0556300796969936354, -0.20397695888897649, 1.05697151424287816)
    ));
    let rec709_to_xyz = transpose(mat3x3<f32>(
        vec3<f32>(0.412390799265959229, 0.357584339383878125, 0.180480788401834347),
        vec3<f32>(0.212639005871510217, 0.71516867876775625, 0.0721923153607337414),
        vec3<f32>(0.0193308187155918181, 0.119194779794626018, 0.950532152249661033)
    ));

    // let cl_src = M16 * rec2020_to_xyz * rec2020_src;
    // let cl_dst = M16 * rec2020_to_xyz * rec2020_dst;
    // var cl = M16 * rec2020_to_xyz * rec2020_d65;
    // cl *= cl_dst / cl_src;
    // return xyz_to_rec2020 * M16i * cl;

    // because were actually in srgb 
    let cl_src = M16 * rec709_to_xyz * rec2020_src;
    let cl_dst = M16 * rec709_to_xyz * rec2020_dst;
    var cl = M16 * rec709_to_xyz * rec2020_d65;
    cl *= cl_dst / cl_src;
    return xyz_to_rec709 * M16i * cl;

}

fn decode_colour(rgb_cam: vec3<f32>) -> vec3<f32> {
    // decode the camera-space color to linear sRGB
    // return mul3x3Rows(img_params.srgb_from_cam, rgb_cam);

    // becasue wgsl mat3x3 layout is column-major, we need to transpose
    return transpose(img_params.srgb_from_cam) * rgb_cam;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let px = textureLoad(input, coords, 0);
    
    let rgb_cam = vec3<f32>(px.r, px.g, px.b);

    // cam -> rgb
    var rgb_srgb_linear = decode_colour(rgb_cam);

    // white balance
    // hmm, vkdt's call cat16(w0, vec3(1.0), params.mul.rgb) with mul=1/w0 DOES produce approximately white (within 1.5% — the small error is because 1/w0 is only approximately the right value due to the
    // g-normalization and the fact that cone-space scaling isn't exactly the same as RGB-space inversion).
    rgb_srgb_linear = cat16(rgb_srgb_linear, vec3f(1.0), params.wb_coeff.rgb);

    let out_px = vec4<f32>(rgb_srgb_linear, px.a);
    textureStore(output, coords, out_px);
}
