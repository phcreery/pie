const std = @import("std");
const libraw = @import("libraw");

const api = @import("../api.zig");

pub const RawImage = struct {
    width: usize,
    height: usize,
    raw_image: []u16,
    cblack: [4]u32,
    white: u32,
    wb_coeff: [4]f32,
    cam_xyz: [3][3]f32,
    filters: api.CFA,
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
        const white: u32 = libraw_rp.*.rawdata.color.maximum;
        const cblack: [4]u32 = libraw_rp.*.rawdata.color.cblack[0..4].*; // TODO: xtans uses more than 4
        const wb_coeff: [4]f32 = libraw_rp.*.rawdata.color.cam_mul; // or pre_mul??
        const cam_xyz_all: [4][3]f32 = libraw_rp.*.rawdata.color.cam_xyz;
        // drop last row
        var cam_xyz: [3][3]f32 = undefined;
        for (cam_xyz_all[0..3], 0..) |row, i| {
            cam_xyz[i] = row;
        }

        return RawImage{
            .width = img_width,
            .height = img_height,
            .raw_image = raw_image,
            .cblack = cblack,
            .white = white,
            .wb_coeff = wb_coeff,
            .cam_xyz = cam_xyz,
            .filters = try api.CFA.fromLibraw(&libraw_rp.*.rawdata.iparams.cdesc, libraw_rp.*.rawdata.iparams.filters),
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
    const file = try std.fs.cwd().openFile("testing/images/DSC_6765.NEF", .{});
    var raw_image = try RawImage.read(allocator, file);
    defer raw_image.deinit();
    try std.testing.expect(raw_image.width == 6016);
    try std.testing.expect(raw_image.height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_width == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.raw_height == 4016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iwidth == 6016);
    try std.testing.expect(raw_image.libraw_rp.sizes.iheight == 4016);
    try std.testing.expectEqual([2][2]api.CFA.FilterColor{
        .{ .R, .G },
        .{ .G2, .B },
    }, raw_image.filters.pattern);
}

pub var desc: api.ModuleDesc = .{
    .name = "i-raw",
    .type = .source,
    .params = init: {
        var p: [api.MAX_PARAMS_PER_MODULE]?api.ParamDesc = @splat(null);
        p[0] = .{ .name = "filename", .len = 256, .typ = .str };
        break :init p;
    },
    .sockets = init: {
        var s: api.Sockets = @splat(null);
        s[0] = .{
            .name = "output",
            .type = .source,
            .format = .rggb16uint,
            .roi = null,
        };
        break :init s;
    },
    .initParams = initParams,
    .init = init,
    .deinit = deinit,
    .modifyROIOut = modifyROIOut,
    .createNodes = createNodes,
    .readSource = readSource,
};

pub fn init(allocator: std.mem.Allocator, pipe: *api.Pipeline, mod_handle: api.ModuleHandle) !void {
    var raw_image = try allocator.create(RawImage);
    errdefer raw_image.deinit();

    const file = try std.fs.cwd().openFile("testing/images/DSC_6765.NEF", .{});
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

pub fn initParams(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "filename", @as([]const u8, "input.raw"));
}

pub fn modifyROIOut(pipe: *api.Pipeline, mod: api.ModuleHandle) !void {
    const m = try api.getModule(pipe, mod);
    const data_ptr = m.desc.data orelse return error.ModuleDataMissing;
    const raw_image = @as(*RawImage, @ptrCast(@alignCast(data_ptr)));
    var roi: api.ROI = .{
        .w = @intCast(raw_image.width),
        .h = @intCast(raw_image.height),
    };

    // THIS IS A WORKAROUND: for single channel read-write storage texture limitation
    roi = roi.div(4, 1); // we have 1/4 width input (packed RG/GB)

    // const float xyz_to_rec2020[] = {
    //     1.7166511880, -0.3556707838, -0.2533662814,
    //     -0.6666843518,  1.6164812366,  0.0157685458,
    //     0.0176398574, -0.0427706133,  0.9421031212
    // };
    const xyz_to_rec2020: [3][3]f32 = .{
        .{ 1.7166511880, -0.3556707838, -0.2533662814 },
        .{ -0.6666843518, 1.6164812366, 0.0157685458 },
        .{ 0.0176398574, -0.0427706133, 0.9421031212 },
    };
    var cam_to_rec2020: [3][3]f32 = undefined;
    api.mat3x3Mul(&cam_to_rec2020, xyz_to_rec2020, raw_image.cam_xyz);

    m.img_param = .{
        .black = [4]f32{
            @as(f32, @floatFromInt(raw_image.cblack[0])),
            @as(f32, @floatFromInt(raw_image.cblack[1])),
            @as(f32, @floatFromInt(raw_image.cblack[2])),
            @as(f32, @floatFromInt(raw_image.cblack[3])),
        },
        .white = [4]f32{
            @as(f32, @floatFromInt(raw_image.white)),
            @as(f32, @floatFromInt(raw_image.white)),
            @as(f32, @floatFromInt(raw_image.white)),
            @as(f32, @floatFromInt(raw_image.white)),
        },
        .white_balance = raw_image.wb_coeff,
        .cam_to_rec2020 = cam_to_rec2020,
    };
    std.debug.print("i-raw module: black={},{},{},{} white={},{},{},{}\n", .{
        m.img_param.?.black[0],
        m.img_param.?.black[1],
        m.img_param.?.black[2],
        m.img_param.?.black[3],
        m.img_param.?.white[0],
        m.img_param.?.white[1],
        m.img_param.?.white[2],
        m.img_param.?.white[3],
    });
    std.debug.print("i-raw module: wb={},{},{},{}\n", .{
        m.img_param.?.white_balance[0],
        m.img_param.?.white_balance[1],
        m.img_param.?.white_balance[2],
        m.img_param.?.white_balance[3],
    });

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
            .name = "source",
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
