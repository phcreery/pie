//! The pipeline's display texture as a sokol image/view.
//!
//! The image is drawn by CUI (image viewer), so this file only injects the
//! wgpu texture the pipeline produced and exposes its view. The CUI renderer
//! borrows the view; it does not own it.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const pie = @import("pie");

pub const DisplayTexture = struct {
    img: sg.Image = .{},
    view: sg.View = .{},
    width: f32 = 0,
    height: f32 = 0,

    pub fn init() DisplayTexture {
        return .{};
    }

    pub fn deinit(self: *DisplayTexture) void {
        self.clear();
    }

    /// Inject the pipeline's display texture (sokol addRefs it and makes its
    /// own view), replacing whatever was there before.
    pub fn setTexture(self: *DisplayTexture, texture: pie.gpu.Texture) void {
        self.clear();
        self.img = sg.makeImage(.{
            .pixel_format = .RGBA16F,
            .width = @intCast(texture.roi.w),
            .height = @intCast(texture.roi.h),
            .wgpu_texture = @ptrCast(texture.texture.texture), // injection
            .label = "display-image-texture",
        });
        self.view = sg.makeView(.{
            .texture = .{ .image = self.img },
            .label = "display-image-texture-view",
        });
        self.width = @floatFromInt(texture.roi.w);
        self.height = @floatFromInt(texture.roi.h);
    }

    pub fn hasTexture(self: *const DisplayTexture) bool {
        return self.img.id != sg.invalid_id and self.view.id != sg.invalid_id;
    }

    pub fn clear(self: *DisplayTexture) void {
        if (self.view.id != sg.invalid_id) sg.destroyView(self.view);
        if (self.img.id != sg.invalid_id) sg.destroyImage(self.img);
        self.view = .{};
        self.img = .{};
        self.width = 0;
        self.height = 0;
    }
};
