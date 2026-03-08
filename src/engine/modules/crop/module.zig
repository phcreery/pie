const api = @import("../api.zig");
const std = @import("std");
const slog = std.log.scoped(.crop);

pub var desc: api.ModuleDesc = .{
    .name = "crop",
    .type = .compute,
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "input",
            .type = .read,
            .format = .rgba16float,
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
    .modifyROIOut = modifyROIOut,
    .createNodes = createNodes,
};

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);
    const input_sock = try api.getModSocket(pipe, mod, "input");
    var roi = input_sock.roi orelse return error.ModuleROIMissing;

    slog.info("Crop module: input ROI: x={}, y={}, w={}, h={}", .{
        roi.x,
        roi.y,
        roi.w,
        roi.h,
    });

    // handle orientation from image metadata (EXIF-style): 1 = normal, 3 = 180, 6 = 90 CW, 8 = 270 CW
    const orientation = m.*.img_param.?.orientation;
    slog.info("Crop module: orientation: {}", .{orientation});

    // if orientation is 6 or 8, we need to swap width and height
    if (orientation == .rotate90CW or orientation == .rotate270CW) {
        const tmp = roi.w;
        roi.w = roi.h;
        roi.h = tmp;
        slog.info("Crop module: swapped width and height due to orientation, new ROI: x={}, y={}, w={}, h={}", .{
            roi.x,
            roi.y,
            roi.w,
            roi.h,
        });
    }
    // roi.w = roi.w - 1; // TESTING - IGNORE

    var output_sock = try api.getModSocket(pipe, mod, "output");
    output_sock.roi = roi;
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");

    const node = try pipe.addNode(mod, .{
        .type = .compute,
        .shader = @embedFile("./crop.wgsl"),
        .name = "crop_rotate",
        .run_size = mod_output_sock.roi.?,
        .sockets = init: {
            var s: api.Sockets = @splat(null);
            s[0] = .{
                .name = "input",
                .type = .read,
                .format = .rgba16float,
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
    });
    try pipe.copyConnector(mod, "input", node, "input");
    try pipe.copyConnector(mod, "output", node, "output");
}
