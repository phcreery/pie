const sokol = @import("sokol");
const shd = @import("texview_shader");
const sg = sokol.gfx;
const pie = @import("pie");

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
            // const fs_params = shd.FsParams{ .mip_lod = 0.0 }; // example of params
            sg.applyPipeline(self.pip);
            sg.applyBindings(bindings);
            // sg.applyUniforms(shd.UB_fs_params, .{ .ptr = &fs_params, .size = @sizeOf(shd.FsParams) });
            sg.draw(0, 4, 1);
        }
    }
};
