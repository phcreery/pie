const ig = @import("cimgui");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const sgl = sokol.gl;
const std = @import("std");
const util = @import("../mem.zig");
const builtin = @import("builtin");

const window = @import("window.zig");
const pie = @import("pie");
const console = @import("console");
const shd = @import("texview_shader");

const Image = struct {
    img: sg.Image = undefined,
    tex_view: sg.View = undefined,
    smp: sg.Sampler = undefined,
    // pip: sg.Pipeline = undefined,
    pip: sgl.Pipeline = undefined,

    width: f32 = 0.0,
    height: f32 = 0.0,
    scale: f32 = 1.0,
    offset: struct { x: f32, y: f32 } = .{ .x = 0.0, .y = 0.0 },
    color: struct { r: f32, g: f32, b: f32 } = .{ .r = 1.0, .g = 1.0, .b = 1.0 },

    // static void create_image(const void* ptr, size_t size) {
    //     reset_image_params();
    //     state.file.qoi_decode_failed = false;
    //     if (state.image.img.id != SG_INVALID_ID) {
    //         sg_destroy_image(state.image.img);
    //         state.image.img.id = SG_INVALID_ID;
    //     }
    //     if (state.image.tex_view.id != SG_INVALID_ID) {
    //         sg_destroy_view(state.image.tex_view);
    //         state.image.tex_view.id = SG_INVALID_ID;
    //     }
    //     qoi_desc qoi;
    //     void* pixels = qoi_decode(ptr, (int)size, &qoi, 4);
    //     if (!pixels) {
    //         state.file.qoi_decode_failed = true;
    //         return;
    //     }
    //     state.image.width = (float) qoi.width;
    //     state.image.height = (float) qoi.height;
    //     state.image.img = sg_make_image(&(sg_image_desc){
    //         .pixel_format = SG_PIXELFORMAT_RGBA8,
    //         .width = qoi.width,
    //         .height = qoi.height,
    //         .data.mip_levels[0] = {
    //             .ptr = pixels,
    //             .size = qoi.width * qoi.height * 4
    //         }
    //     });
    //     state.image.tex_view = sg_make_view(&(sg_view_desc){
    //         .texture.image = state.image.img,
    //     });
    //     free(pixels);
    // }
    fn create(self: *@This(), texture: *pie.gpu.Texture) void {
        // self.texture = texture;
        // sg.uninitImage(self.img);
        self.width = @floatFromInt(texture.roi.w);
        self.height = @floatFromInt(texture.roi.h);
        self.scale = 1.0;
        self.offset = .{ .x = 0.0, .y = 0.0 };
        self.color = .{ .r = 1.0, .g = 1.0, .b = 1.0 };
        self.img = sg.makeImage(.{
            .pixel_format = .RGBA16F,
            .width = texture.roi.w,
            .height = texture.roi.h,
            .data = .{
                .mip_levels = &.{.{ .ptr = texture.data, .size = texture.data_len }},
            },
        });
        // sg.initImage(self.img, .{
        //     .pixel_format = .RGBA16F,
        //     .width = texture.roi.w,
        //     .height = texture.roi.h,
        //     .data = .{
        //         .mip_levels = &.{.{ .ptr = texture.data, .size = texture.data_len }},
        //     },
        // });
        self.tex_view = sg.makeView(.{
            .texture = self.img,
        });
    }
};

const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pass_action: sg.PassAction = .{},
    window: window.WindowManager,
    image: Image = undefined,

    gpu: pie.gpu.GPU = undefined,
    pipeline: *pie.pipeline.Pipeline = undefined,
    modules: *pie.modules.Registry = undefined,
    arena: std.mem.Allocator = undefined,

    texture: *pie.gpu.Texture = undefined,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        const windowmgr = window.WindowManager.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .pass_action = .{},
            .window = windowmgr,
            .image = Image{},
        };
    }

    fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.window.deinit(allocator);
        self.deinit();
        allocator.destroy(self);
    }
};

// export fn init() void {
export fn init_fn(ptr: ?*anyopaque) void {
    std.debug.print("init_fn called with ptr: {any}\n", .{ptr});
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // initialize sokol-gfx
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    // initialize sokol-imgui
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.5, .b = 1.0, .a = 1.0 },
    };

    // USING SGL
    state.image.pip = sgl.makePipeline(.{
        .colors = init: {
            var c: @FieldType(sg.PipelineDesc, "colors") = @splat(.{});
            c[0] = .{
                .write_mask = .RGB,
                .blend = .{
                    .enabled = true,
                    .src_factor_rgb = .SRC_ALPHA,
                    .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                },
            };
            break :init c;
        },
    });

    state.image.smp = sg.makeSampler(.{
        .mag_filter = .NEAREST,
        .min_filter = .LINEAR,
        // .wrap_u = .CLAMP_TO_EDGE,
        // .wrap_v = .CLAMP_TO_EDGE,
    });

    std.debug.print("making pipeline...\n", .{});
    // pre-allocate handles so we can keep rendering even no
    // image has been loaded yet
    state.image.img = sg.allocImage();
    state.image.tex_view = sg.allocView();

    // USING SG
    // create pipeline and shader for rendering into display
    // const pip_desc: sg.PipelineDesc = .{
    //     .shader = sg.makeShader(shd.texviewShaderDesc(sg.queryBackend())),
    //     .primitive_type = .TRIANGLE_STRIP,
    // };
    // pip_desc.layout.attrs[shd.ATTR_display_pos].format = .FLOAT2;
    // state.image.pip = sg.makePipeline(pip_desc); // note, sg. or sgl.? (qoi example uses sgl, but texview sample uses sg)

    // state.image.pip = sgl.makePipeline(pip_desc);

    state.texture = build_image(
        state.allocator,
        state.io,
        state.pipeline,
        state.modules,
        state.arena,
    ) catch unreachable;
    std.debug.print("texture: {any}\n", .{state.texture});
}

export fn frame(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));

    // call simgui.newFrame() before any ImGui calls
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    // === UI CODE STARTS HERE

    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once);
    ig.igSetNextWindowSize(.{ .x = 400, .y = 100 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("Hello Dear ImGui!", 0, ig.ImGuiWindowFlags_None);
    _ = ig.igColorEdit3("Background", &state.pass_action.colors[0].clear_value.r, ig.ImGuiColorEditFlags_None);
    ig.igEnd();

    // std.debug.print("frame state\n", .{});
    // std.debug.print("{any}\n", .{state});

    // const float disp_w = sapp_widthf();
    // const float disp_h = sapp_heightf();
    const disp_w = sapp.widthf();
    const disp_h = sapp.heightf();
    sgl.defaults();
    sgl.enableTexture();
    sgl.matrixModeProjection();
    sgl.ortho(-disp_w * 0.5, disp_w * 0.5, disp_h * 0.5, -disp_h * 0.5, -1.0, 1.0);

    if (state.image.img.id != sg.invalid_id) {
        // display the image
        // const float x0 = ((-state.image.width * 0.5f) * state.image.scale) + (state.image.offset.x * state.image.scale);
        // const float x1 = x0 + (state.image.width * state.image.scale);
        // const float y0 = ((-state.image.height * 0.5f) * state.image.scale) + (state.image.offset.y * state.image.scale);
        // const float y1 = y0 + (state.image.height * state.image.scale);

        // sgl_texture(state.image.tex_view, state.image.smp);
        // sgl_load_pipeline(state.image.pip);
        // sgl_c3f(state.image.color.r, state.image.color.g, state.image.color.b);
        // sgl_begin_quads();
        // sgl_v2f_t2f(x0, y0, 0.0f, 0.0f);
        // sgl_v2f_t2f(x1, y0, 1.0f, 0.0f);
        // sgl_v2f_t2f(x1, y1, 1.0f, 1.0f);
        // sgl_v2f_t2f(x0, y1, 0.0f, 1.0f);
        // sgl_end();

        const x0: f32 = ((-state.image.width * 0.5) * state.image.scale) + (state.image.offset.x * state.image.scale);
        const x1: f32 = x0 + (state.image.width * state.image.scale);
        const y0: f32 = ((-state.image.height * 0.5) * state.image.scale) + (state.image.offset.y * state.image.scale);
        const y1: f32 = y0 + (state.image.height * state.image.scale);

        sgl.texture(state.image.tex_view, state.image.smp);
        sgl.loadPipeline(state.image.pip);
        sgl.c3f(state.image.color.r, state.image.color.g, state.image.color.b);
        sgl.beginQuads();
        sgl.v2fT2f(x0, y0, 0.0, 0.0);
        sgl.v2fT2f(x1, y0, 1.0, 0.0);
        sgl.v2fT2f(x1, y1, 1.0, 1.0);
        sgl.v2fT2f(x0, y1, 0.0, 1.0);
        sgl.end();
    }

    state.window.render();

    // === UI CODE ENDS HERE

    // call simgui.render() inside a sokol-gfx pass
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    simgui.render();
    sg.endPass();
    sg.commit();
}

export fn cleanup(ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    _ = state;
    simgui.shutdown();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event, ptr: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(ptr));
    _ = state;
    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);
}

fn build_image(
    allocator: std.mem.Allocator,
    io: std.Io,
    pipeline: *pie.pipeline.Pipeline,
    modules: *pie.modules.Registry,
    arena: std.mem.Allocator,
) !*pie.gpu.Texture {
    _ = allocator;
    _ = io;

    // const config: pie.gpu.TargetConfig = @import("001_DSC_6765/target.zig").config;
    // const target_filename = "testing/integration/targets/" ++ config.name ++ "/target.ppm";
    const input_filename = "testing/images/DSC_6765.NEF";
    // const output_filename = "testing/integration/targets/" ++ config.name ++ "/output.ppm";

    const mod_i_raw = try pipeline.addModule(modules.get("i-raw").?);
    const mod_format = try pipeline.addModule(modules.get("format").?);
    const mod_denoise = try pipeline.addModule(modules.get("denoise").?);
    // const mod_whitebalance = try pipeline.addModule(modules.get("whitebalance").?);
    const mod_demosaic = try pipeline.addModule(modules.get("demosaic").?);
    const mod_crop = try pipeline.addModule(modules.get("crop").?);
    const mod_color = try pipeline.addModule(modules.get("color").?);
    const mod_filmcurv = try pipeline.addModule(modules.get("filmcurv").?);
    // const mod_test_nop_glsl = try pipeline.addModule(modules.get("test-nop-glsl").?);
    // const mod_test_nop_zig = try pipeline.addModule(modules.get("test-nop-zig").?);
    const mod_o_display = try pipeline.addModule(modules.get("o-display").?);

    try pipeline.setModuleParam(mod_i_raw, "filename", @as([]const u8, input_filename));
    try pipeline.setModuleParam(mod_i_raw, "wb_mode", @as(i32, 0));
    // try pipeline.setModuleParam(mod_color, "wb_temp", @as(f32, 6500.0));
    try pipeline.setModuleParam(mod_color, "wb_tint", @as(f32, 0.0));
    try pipeline.setModuleParam(mod_color, "wb_coeff", [3]f32{ 0.70393723, 1, 1.3611937 }); // from 1/(srgb_from_xyz*xyz_d65_from_cam*(1/wb_cam)) of DSC_6765.NEF
    try pipeline.setModuleParam(mod_filmcurv, "colormode", @as(i32, 1));
    try pipeline.setModuleParam(mod_filmcurv, "brightness", @as(f32, 3.8));
    try pipeline.setModuleParam(mod_filmcurv, "contrast", @as(f32, 1.3));
    try pipeline.setModuleParam(mod_filmcurv, "bias", @as(f32, 0.0));
    // try pipeline.setModuleParam(mod_o_display, "filename", @as([]const u8, output_filename));

    try pipeline.connectModuleSocketsByHandleName(mod_i_raw, "output", mod_format, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_format, "output", mod_denoise, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_denoise, "output", mod_whitebalance, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_whitebalance, "output", mod_demosaic, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_denoise, "output", mod_demosaic, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_demosaic, "output", mod_crop, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_crop, "output", mod_color, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_color, "output", mod_filmcurv, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_filmcurv, "output", mod_test_nop_glsl, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_test_nop_glsl, "output", mod_test_nop_zig, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_test_nop_zig, "output", mod_o_ppm, "input");
    // try pipeline.connectModuleSocketsByHandleName(mod_test_nop_glsl, "output", mod_o_ppm, "input");
    try pipeline.connectModuleSocketsByHandleName(mod_filmcurv, "output", mod_o_display, "input");

    try pipeline.run(arena);

    const disp_tex = try pipeline.getDisplaySinkTexture();
    // Use the display texture for rendering
    return disp_tex;
}

pub fn run(init: std.process.Init) !void {
    // general purpose allocator for temporary heap allocations:
    // const gpa = init.gpa;
    const allocator = util.allocator;
    // default Io implementation:
    const io = init.io;
    // access to environment variables:
    // std.log.info("{d} env vars", .{init.environ_map.count()});
    // access to CLI arguments
    // const args = try init.minimal.args.toSlice(
    //     init.arena.allocator()
    // );

    // Allocate the application state on the heap to ensure it lives long enough.
    // const state = util.allocator.create(AppState) catch unreachable;
    // errdefer util.allocator.destroy(state);
    // state.* = AppState.init(util.allocator);

    // Alternatively, allocate the application state on the stack
    const state: *AppState = @constCast(&AppState.init(allocator, io));
    defer state.deinit();

    const cout = console.console.UTF8ConsoleOutput.init();
    defer cout.deinit();

    var gpu_instance = try pie.gpu.GPU.init(io);
    // defer gpu_instance.deinit();
    state.gpu = gpu_instance;

    var modules = try pie.modules.Registry.init(allocator);
    // defer modules.deinit();
    state.modules = &modules;

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    // defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    state.arena = arena;

    const pipeline_config: pie.pipeline.PipelineConfig = .{
        .upload_buffer_size_bytes = 75e6,
        .download_buffer_size_bytes = 75e6,
    };

    var pipeline = pie.Pipeline.init(allocator, io, &gpu_instance, pipeline_config) catch unreachable;
    // defer pipeline.deinit();
    state.pipeline = &pipeline;

    sapp.run(.{
        .user_data = state,
        .init_userdata_cb = init_fn,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .window_title = "PIE",
        .width = 800,
        .height = 600,
        .logger = .{ .func = slog.func },
    });
}
