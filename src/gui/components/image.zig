const sokol = @import("sokol");
const shd = @import("texview_shader");
const sg = sokol.gfx;
const sapp = sokol.app;
const std = @import("std");
const pie = @import("pie");

/// Interactive view transform for the displayed image.
///
/// The fullscreen quad is shrunk so the image keeps its original aspect ratio
/// (letterboxed "contain" fit inside the window). On top of that base fit we
/// apply a user-controlled `zoom` (mouse wheel) and `pan` offset (mouse drag),
/// both expressed in normalized device coordinates.
pub const View = struct {
    /// zoom factor, 1.0 = base fit, <1.0 = zoomed out, >1.0 = zoomed in
    zoom: f32 = 1.0,
    /// pan offset in NDC [-1..1]
    pan: [2]f32 = .{ 0.0, 0.0 },

    dragging: bool = false,
    last_mouse: [2]f32 = .{ 0.0, 0.0 },
    last_zoom: f32 = 1.0,

    const Self = @This();

    /// Recompute the per-frame `scale` (aspect-corrected base fit * zoom).
    pub fn scaleFor(self: Self, img_w: f32, img_h: f32, win_w: f32, win_h: f32) [2]f32 {
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
        return .{ base[0] * self.zoom, base[1] * self.zoom };
    }
};

pub const Image = struct {
    // sokol
    img: sg.Image = undefined,
    tex_view: sg.View = undefined,
    smp: sg.Sampler = undefined,
    shd: sg.Shader = undefined,
    pip: sg.Pipeline = undefined,

    // meta
    width: f32 = 0.0,
    height: f32 = 0.0,

    // interactive pan/zoom
    view: View = .{},

    const Self = @This();

    pub fn init() Self {
        var image = Self{};

        // initialize state.image
        image.smp = sg.makeSampler(.{
            .mag_filter = .NEAREST,
            .min_filter = .LINEAR,
            // .wrap_u = .CLAMP_TO_EDGE,
            // .wrap_v = .CLAMP_TO_EDGE,
        });
        image.shd = sg.makeShader(shd.texviewShaderDesc(sg.queryBackend()));
        image.pip = sg.makePipeline(.{
            .shader = image.shd,
            .primitive_type = .TRIANGLE_STRIP,
            .color_count = 1,
            // .sample_count = sc.sample_count, // sc = sglue.swapchain()
            // .depth = .{ .pixel_format = sc.depth_format },
            .colors = init: {
                var c: @FieldType(sg.PipelineDesc, "colors") = @splat(.{});
                c[0] = .{
                    // .pixel_format = sc.color_format,
                    .write_mask = .RGBA,
                };
                break :init c;
            },
        });

        return image;
    }

    pub fn createFrom(self: *Self, texture: *pie.gpu.Texture) void {
        // Inject the existing GPU-side WebGPU texture into sokol instead of
        // trying to upload CPU pixel data. sokol will addRef() the texture and
        // create its own WGPUTextureView when we make the sg.View.
        self.img = sg.makeImage(.{
            .pixel_format = .RGBA16F,
            .width = @intCast(texture.roi.w),
            .height = @intCast(texture.roi.h),
            .wgpu_texture = @ptrCast(texture.texture), // injection
            .label = "display-texture",
        });
        self.tex_view = sg.makeView(.{
            .texture = .{ .image = self.img },
            .label = "display-texture-view",
        });
        self.width = @floatFromInt(texture.roi.w);
        self.height = @floatFromInt(texture.roi.h);
    }

    /// Handle a sokol_app event. Returns nothing; mutates `view`.
    pub fn input(self: *Self, ev: *const sapp.Event) void {
        const v = &self.view;
        switch (ev.type) {
            .MOUSE_DOWN => {
                if (ev.mouse_button == .LEFT) {
                    v.dragging = true;
                    v.last_mouse = .{ ev.mouse_x, ev.mouse_y };
                }
            },
            .MOUSE_UP => {
                if (ev.mouse_button == .LEFT) v.dragging = false;
            },
            .MOUSE_MOVE => {
                if (v.dragging) {
                    const ww = @as(f32, @floatFromInt(ev.framebuffer_width));
                    const wh = @as(f32, @floatFromInt(ev.framebuffer_height));
                    if (ww > 0 and wh > 0) {
                        const dx_ndc = (ev.mouse_x - v.last_mouse[0]) / (ww * 0.5);
                        const dy_ndc = -(ev.mouse_y - v.last_mouse[1]) / (wh * 0.5);
                        v.pan[0] += dx_ndc;
                        v.pan[1] += dy_ndc;
                    }
                    v.last_mouse = .{ ev.mouse_x, ev.mouse_y };
                }
            },
            .MOUSE_SCROLL => {
                const factor = std.math.pow(f32, 1.1, -ev.scroll_y);
                v.last_zoom = v.zoom;
                v.zoom = std.math.clamp(v.zoom * factor, 0.05, 64.0);

                // Zoom toward the cursor
                const ww = @as(f32, @floatFromInt(ev.framebuffer_width));
                const wh = @as(f32, @floatFromInt(ev.framebuffer_height));
                if (ww > 0 and wh > 0 and v.last_zoom > 0) {
                    // cursor in NDC (screen center = 0, y up)
                    const cx = (ev.mouse_x - (ww * 0.5)) / (ww * 0.5);
                    const cy = -(ev.mouse_y - (wh * 0.5)) / (wh * 0.5);
                    const r = v.zoom / v.last_zoom;
                    v.pan[0] += (1.0 - r) * (cx - v.pan[0]);
                    v.pan[1] += (1.0 - r) * (cy - v.pan[1]);
                }
            },
            else => {},
        }
    }

    pub fn draw(self: *Self) void {
        const have_image = self.img.id != sg.invalid_id and self.tex_view.id != sg.invalid_id;
        if (have_image) {
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

            const ww = sapp.widthf();
            const wh = sapp.heightf();
            const scale = self.view.scaleFor(self.width, self.height, ww, wh);
            const vs_params = shd.VsParams{
                .scale = scale,
                .offset = self.view.pan,
            };

            sg.applyPipeline(self.pip);
            sg.applyBindings(bindings);
            sg.applyUniforms(shd.UB_vs_params, .{ .ptr = &vs_params, .size = @sizeOf(shd.VsParams) });
            sg.draw(0, 4, 1);
        }
    }
};
