const api = @import("../api.zig");
const std = @import("std");

pub var module: api.ModuleDesc = .{
    .name = "demosaic",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rggb16float,
            .roi = null,
        };
        s[1] = .{
            .name = "output",
            .type = .write,
            .format = .rgba16float,
            .roi = null,
        };
        break :init s;
    },
    .createNodes = createNodes,
    .modifyROIOut = modifyROIOut,
};

fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const input_sock = try api.getModSocket(pipe, mod, "input");
    var roi: api.ROI = input_sock.roi.?;
    // const roi_half = roi.div(2, 2);
    // we have packed RG/GB
    const roi_half = roi.scaled(2, 0.5);
    var output_sock = try api.getModSocket(pipe, mod, "output");
    output_sock.roi = roi_half;
}

// DEMOSAIC WITH COMPUTE SHADER
const shader_code: []const u8 =
    \\enable f16;
    \\@group(1) @binding(0) var input:  texture_2d<f32>;
    \\@group(1) @binding(1) var output: texture_storage_2d<rgba16float, write>;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    \\    var coords = vec2<i32>(global_id.xy);
    \\    // INPUT
    \\    // libraw outputs the raw data as a 1D buffer, but we interpret it as a 2D texture
    \\    // [ [(r g r g)] [ r g r g ] ...
    \\    //   [ g b g b ] [(g b g b)] ...
    \\    //   [ r g r g ] [ r g r g ] ...
    \\    //   [ g b g b ] [ g b g b ] ... ]
    \\    // iw,ih == raw_width/4, raw_height
    \\    // the reason raw_width is divided by 4 is that raw_width is not the number
    \\    // of pixels (RG/GB), but the number of photosensors (R or G or B)
    \\    // so we divide by four to get the correct width in "RGBA" pixels
    \\    // when we index this texture, we will get
    \\    // (0,0) -> [ r g r g ]  // wrong
    \\    // (1,1) -> [ g b g b ]  // wrong
    \\    //
    \\    // we want the mosaic
    \\    // [  /r g\ r g  r g  r g ...
    \\    //    \g b/ g b  g b  g b ...
    \\    //     r g /r g\ r g  r g ...
    \\    //     g b \g b/ g b  g b ... ]
    \\    //  w,h  =  raw_width/2, raw_height/2
    \\    // so that an invocation coord of
    \\    // (0,0) -> [ r g g b ]
    \\    // (1,1) -> [ r g g b ]
    \\    // 
    \\    // OUTPUT
    \\    // we want pixels to be reconstructed as:
    \\    // [ [(r g b 1)] [ r g b 1 ] ...
    \\    //   [ r g b 1 ] [(r g b 1)] ...
    \\    //   [ r g b 1 ] [ r g b 1 ] ...
    \\    //   [ r g b 1 ] [ r g b 1 ] ... ]
    \\    // ow,oh == raw_width/2, raw_height/2
    \\    // (0,0) -> [ r g b 1 ]  // correct
    \\    // (1,1) -> [ r g b 1 ]  // correct
    \\    //
    \\    // DECODE
    \\    var r: f32;
    \\    var g1: f32;
    \\    var g2: f32;
    \\    var b: f32;
    \\    let base_coords_x: i32 = coords.x / 2; // integer division
    \\    let base_coords_y: i32 = coords.y * 2;
    \\    let is_even_x = (coords.x % 2) == 0;
    \\    if (is_even_x) {
    \\        r = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).r;
    \\        g1 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).g;
    \\        g2 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).r;
    \\        b = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).g;
    \\    } else {
    \\        r = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).b;
    \\        g1 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 0), 0).a;
    \\        g2 = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).b;
    \\        b = textureLoad(input, vec2<i32>(base_coords_x, base_coords_y + 1), 0).a;
    \\    }
    \\    let g = (g1 + g2) / 2.0;
    \\    let rgba = vec4<f32>(r, g, b, 1);
    \\    textureStore(output, coords, rgba);
    \\}
;
pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = shader_code,
        .name = "halfsize",
        .run_size = mod_output_sock.roi,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rggb16float,
                .roi = null,
            };
            s[1] = .{
                .name = "output",
                .type = .write,
                .format = .rgba16float,
                .roi = null,
            };
            break :init s;
        },
    };
    const node = try pipe.addNode(mod, node_desc);
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
