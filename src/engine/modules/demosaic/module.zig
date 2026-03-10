const api = @import("../api.zig");
const std = @import("std");

pub var desc: api.ModuleDesc = .{
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

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_desc: api.NodeDesc = .{
        .type = .compute,
        .shader = @embedFile("./halfsize.wgsl"),
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
