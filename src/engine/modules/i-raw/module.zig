const std = @import("std");
const libraw = @import("libraw");
const CFA = @import("../shared/CFA.zig");

const api = @import("../api.zig");

pub const RawImage = struct {
    width: usize,
    height: usize,
    raw_image: []u16,
    max_value: u32,
    filters: CFA,
    libraw_rp: *libraw.libraw_data_t,

    pub fn read(allocator: std.mem.Allocator, file: std.fs.File) !RawImage {
        const file_info = try file.stat();

        // create buffer and read entire file into it
        var buf: []u8 = try allocator.alloc(u8, file_info.size);
        defer allocator.free(buf);
        _ = try file.read(buf[0..]);

        const libraw_rp = libraw.libraw_init(0);

        const ret = libraw.libraw_open_buffer(libraw_rp, buf.ptr, buf.len);
        if (ret != libraw.LIBRAW_SUCCESS) {
            return error.OpenFailed;
        }
        const ret2 = libraw.libraw_unpack(libraw_rp);
        if (ret2 != libraw.LIBRAW_SUCCESS) {
            return error.UnpackFailed;
        }
        // TODO: some of the stuff libraw.libraw_raw2image(libraw_rp); does

        const img_width: u16 = libraw_rp.*.sizes.width;
        const img_height: u16 = libraw_rp.*.sizes.height;
        const raw_image: []u16 = std.mem.span(libraw_rp.*.rawdata.raw_image);
        // const raw_pixel_count = @as(u32, img_width) * img_height;
        const max_value: u32 = libraw_rp.*.rawdata.color.maximum;

        return RawImage{
            .width = img_width,
            .height = img_height,
            .raw_image = raw_image,
            .max_value = max_value,
            .filters = try CFA.fromLibraw(&libraw_rp.*.rawdata.iparams.cdesc, libraw_rp.*.rawdata.iparams.filters),
            .libraw_rp = libraw_rp,
        };
    }

    pub fn deinit(self: *RawImage) void {
        libraw.libraw_recycle(self.libraw_rp);
        libraw.libraw_close(self.libraw_rp);
    }
};

test "libraw version" {
    const version = libraw.libraw_version();
    std.log.info("LibRaw version: {s}", .{version});
    try std.testing.expect(version.len > 0);
}

test "open raw image" {
    const allocator = std.testing.allocator;
    const file = try std.fs.cwd().openFile("testing/integration/fullsize/DSC_6765.NEF", .{});
    var raw_image = try RawImage.read(allocator, file);
    defer raw_image.deinit();
    try std.testing.expect(raw_image.width == 6016);
    try std.testing.expect(raw_image.height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_width == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iwidth == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iheight == 4016);
    try std.testing.expectEqual([2][2]CFA.FilterColor{
        .{ .R, .G },
        .{ .G2, .B },
    }, raw_image.filters.pattern);
}

pub var module: api.ModuleDesc = .{
    .name = "i-raw",
    .type = .source,
    // .params = init: {
    //     var p: [api.MAX_PARAMS_PER_MODULE]?api.Param = @splat(null);
    //     p[0] = .{ .name = "filename", .value = .{ .str = "DSC_6765.NEF" } };
    //     break :init p;
    // },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "output",
            .type = .source,
            .format = .rgba16uint,
            .roi = null,
        };
        break :init s;
    },
    .init = init,
    .deinit = deinit,
    .readSource = readSource,
    .writeSink = null,
    .createNodes = createNodes,
    .modifyROIOut = modifyROIOut,
};

pub fn init(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod_handle: api.ModuleHandle) !void {
    var raw_image = try allocator.create(RawImage);
    errdefer raw_image.deinit();

    const file = try std.fs.cwd().openFile("testing/integration/fullsize/DSC_6765.NEF", .{});
    raw_image.* = try RawImage.read(allocator, file);
    errdefer raw_image.deinit();

    var mod = try api.getModule(pipe, mod_handle);
    mod.desc.data = raw_image;
}

pub fn deinit(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod: api.ModuleHandle) void {
    const m = api.getModule(pipe, mod) catch return;
    const data_ptr = m.desc.data orelse return;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    raw_image.deinit();
    allocator.destroy(raw_image);
}

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    const roi: api.ROI = .{
        .w = @intCast(raw_image.width),
        .h = @intCast(raw_image.height),
    };
    // TODO:
    // we have packed RG/GB
    // roi = roi.div(2, 2);

    var socket = try api.getModSocket(pipe, mod, "output");
    socket.roi = roi;
}

pub fn readSource(pipe: *api.Pipeline, mod: api.ModuleHandle, mapped: *anyopaque) !void {
    const m = try api.getModule(pipe, mod);
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));

    const upload_buffer_ptr: [*]u16 = @ptrCast(@alignCast(mapped));
    @memcpy(upload_buffer_ptr, raw_image.raw_image);
}

pub fn createNodes(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const same_as_mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node = try api.addNode(
        pipe,
        mod,
        .{
            .type = .source,
            .name = "Source",
            .run_size = null,
            .sockets = init: {
                var s: api.Sockets = @splat(null);
                s[0] = same_as_mod_output_sock.*;
                break :init s;
            },
        },
    );
    try api.copyConnector(pipe, mod, "output", node, "output");
}
