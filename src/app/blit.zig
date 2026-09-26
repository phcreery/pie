//! sokol-gfx resources that draw the pipeline's display texture as a
//! letterboxed fullscreen quad.
//!
//! Host-owned: blitting a texture into the swapchain pass is stable code, so it
//! stays out of the hot-reloadable plugin. Only the view transform (zoom/pan)
//! comes from the plugin, through the host-owned `abi.SharedState`.

const std = @import("std");
const sokol = @import("sokol");
const shd = @import("texview_shader");
const sg = sokol.gfx;
const sapp = sokol.app;
const pie = @import("pie");

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

    pub fn draw(self: *Blit, zoom: f32, pan: [2]f32) void {
        if (!self.hasTexture()) return;

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

        const scale = scaleFor(self.width, self.height, sapp.widthf(), sapp.heightf(), zoom);
        const vs_params = shd.VsParams{
            .scale = scale,
            .offset = pan,
        };

        sg.applyPipeline(self.pip);
        sg.applyBindings(bindings);
        sg.applyUniforms(shd.UB_vs_params, .{ .ptr = &vs_params, .size = @sizeOf(shd.VsParams) });
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
