//! sokol-gfx resources that draw the pipeline's display texture as a
//! letterboxed quad.
//!
//! Part of the editing session: blitting a texture into the swapchain pass is
//! stable code, so it stays out of the GUI. The darkroom supplies only the view
//! transform (zoom/pan) and the screen region the image may occupy.

const std = @import("std");
const sokol = @import("sokol");
const shd = @import("texview_shader");
const sg = sokol.gfx;
const sapp = sokol.app;
const pie = @import("pie");

pub const Rect = struct {
    /// top-left corner and size, in framebuffer pixels
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Blit = struct {
    img: sg.Image = .{},
    tex_view: sg.View = .{},
    smp: sg.Sampler = .{},
    shd: sg.Shader = .{},
    pip: sg.Pipeline = .{},

    width: f32 = 0,
    height: f32 = 0,

    pub fn init() Blit {
        var self: Blit = .{};
        self.createResources();
        return self;
    }

    pub fn deinit(self: *Blit) void {
        self.clearTexture();
        self.destroyResources();
    }

    /// Inject the pipeline's display texture (sokol addRefs it and makes its
    /// own view), replacing whatever was there before.
    pub fn setTexture(self: *Blit, texture: pie.gpu.Texture) void {
        self.clearTexture();
        self.img = sg.makeImage(.{
            .pixel_format = .RGBA16F,
            .width = @intCast(texture.roi.w),
            .height = @intCast(texture.roi.h),
            .wgpu_texture = @ptrCast(texture.texture.texture), // injection
            .label = "display-image-texture",
        });
        self.tex_view = sg.makeView(.{
            .texture = .{ .image = self.img },
            .label = "display-image-texture-view",
        });
        self.width = @floatFromInt(texture.roi.w);
        self.height = @floatFromInt(texture.roi.h);
    }

    pub fn hasTexture(self: *const Blit) bool {
        return self.img.id != sg.invalid_id and self.tex_view.id != sg.invalid_id;
    }

    /// Letterboxed "contain" fit of the image inside the window, times the
    /// user's zoom. Returned as the NDC scale of a [-1,1] quad.
    pub fn scaleFor(img_w: f32, img_h: f32, win_w: f32, win_h: f32, zoom: f32) [2]f32 {
        const img_aspect = img_w / img_h;
        const win_aspect = if (win_h > 0) win_w / win_h else 1.0;

        // "contain" fit: image is scaled so its longest side touches the window.
        var base: [2]f32 = .{ 1.0, 1.0 };
        if (img_aspect > win_aspect) {
            // image is wider than the window -> shrink vertically
            base[1] = win_aspect / img_aspect;
        } else {
            // image is taller than the window -> shrink horizontally
            base[0] = img_aspect / win_aspect;
        }
        return .{ base[0] * zoom, base[1] * zoom };
    }

    /// Draw the image letterboxed (and panned/zoomed) inside `rect`, a region
    /// of the framebuffer in pixels. `zoom`/`pan` are relative to that region:
    /// pan 1.0 moves the image half a region, so panning feels the same at any
    /// region size. The image is clipped to the region.
    pub fn draw(self: *Blit, zoom: f32, pan: [2]f32, rect: Rect) void {
        if (!self.hasTexture()) return;

        const win_w = sapp.widthf();
        const win_h = sapp.heightf();
        if (win_w <= 0 or win_h <= 0 or rect.w <= 0 or rect.h <= 0) return;

        // the region's center and half-size as fractions of the full screen NDC
        const center_x = ((rect.x + rect.w * 0.5) / win_w) * 2.0 - 1.0;
        const center_y = 1.0 - ((rect.y + rect.h * 0.5) / win_h) * 2.0;
        const half_x = rect.w / win_w;
        const half_y = rect.h / win_h;

        const bindings = sg.Bindings{
            .views = init: {
                var v: @FieldType(sg.Bindings, "views") = @splat(.{});
                v[shd.VIEW_tex] = self.tex_view;
                break :init v;
            },
            .samplers = init: {
                var s: @FieldType(sg.Bindings, "samplers") = @splat(.{});
                s[shd.SMP_smp] = self.smp;
                break :init s;
            },
        };

        const base = scaleFor(self.width, self.height, rect.w, rect.h, zoom);
        const vs_params = shd.VsParams{
            .scale = .{ base[0] * half_x, base[1] * half_y },
            .offset = .{ center_x + half_x * pan[0], center_y + half_y * pan[1] },
        };

        sg.applyPipeline(self.pip);
        sg.applyBindings(bindings);
        sg.applyUniforms(shd.UB_vs_params, .{ .ptr = &vs_params, .size = @sizeOf(shd.VsParams) });
        sg.applyScissorRect(
            @intFromFloat(rect.x),
            @intFromFloat(rect.y),
            @intFromFloat(rect.w),
            @intFromFloat(rect.h),
            true,
        );
        sg.draw(0, 4, 1);
    }

    fn createResources(self: *Blit) void {
        self.smp = sg.makeSampler(.{
            .mag_filter = .NEAREST,
            .min_filter = .LINEAR,
        });
        self.shd = sg.makeShader(shd.texviewShaderDesc(sg.queryBackend()));
        self.pip = sg.makePipeline(.{
            .shader = self.shd,
            .primitive_type = .TRIANGLE_STRIP,
            .color_count = 1,
            .colors = init: {
                var c: @FieldType(sg.PipelineDesc, "colors") = @splat(.{});
                c[0] = .{
                    .write_mask = .RGBA,
                };
                break :init c;
            },
        });
    }

    fn destroyResources(self: *Blit) void {
        if (self.smp.id != sg.invalid_id) sg.destroySampler(self.smp);
        if (self.pip.id != sg.invalid_id) sg.destroyPipeline(self.pip);
        if (self.shd.id != sg.invalid_id) sg.destroyShader(self.shd);
        self.smp = .{};
        self.pip = .{};
        self.shd = .{};
    }

    fn clearTexture(self: *Blit) void {
        if (self.tex_view.id != sg.invalid_id) sg.destroyView(self.tex_view);
        if (self.img.id != sg.invalid_id) sg.destroyImage(self.img);
        self.tex_view = .{};
        self.img = .{};
    }
};
