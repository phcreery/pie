//! CUI renderer for sokol-gfx (the app uses the wgpu backend).
//!
//! CUI emits one vertex format and a short list of draw commands (see
//! docs/rendering.md). Textures are owned by this renderer; fonts are rebuilt
//! from a CPU mirror when CUI updates the atlas, app textures (the display
//! image, thumbnails) are registered as borrowed views.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const shd = @import("cui_shader");
const cui = @import("cui");

const vertex_stride: usize = 64;
const initial_vertex_bytes: usize = 1 << 20;
const initial_index_bytes: usize = 512 * 1024;

pub const Renderer = struct {
    allocator: std.mem.Allocator,

    shader: sg.Shader = .{},
    pipeline: sg.Pipeline = .{},
    sampler: sg.Sampler = .{},

    vertex_buffer: sg.Buffer = .{},
    index_buffer: sg.Buffer = .{},
    vertex_capacity: usize = 0,
    index_capacity: usize = 0,

    textures: std.ArrayListUnmanaged(Texture) = .empty,
    free_handles: std.ArrayListUnmanaged(usize) = .empty,

    const Texture = struct {
        alive: bool = false,
        owned: bool = false,
        view: sg.View = .{},
        image: sg.Image = .{},
        width: u32 = 0,
        height: u32 = 0,
        format: cui.cui_texture_format = cui.CUI_TEXTURE_RGBA8,
        cpu: []u8 = &.{},
        rebuild: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        var self = Renderer{ .allocator = allocator };
        self.sampler = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .mipmap_filter = .NEAREST,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
            .label = "cui-sampler",
        });
        self.shader = sg.makeShader(shd.cuiShaderDesc(sg.queryBackend()));
        if (self.shader.id == sg.invalid_id) return error.ShaderCreationFailed;

        var layout: sg.VertexLayoutState = .{};
        layout.buffers[0] = .{
            .stride = vertex_stride,
            .step_func = .PER_VERTEX,
        };
        layout.attrs[0] = .{ .offset = 0, .format = .FLOAT2 }; // pos
        layout.attrs[1] = .{ .offset = 8, .format = .FLOAT2 }; // uv
        layout.attrs[2] = .{ .offset = 16, .format = .FLOAT2 }; // local
        layout.attrs[3] = .{ .offset = 24, .format = .FLOAT2 }; // half
        layout.attrs[4] = .{ .offset = 32, .format = .FLOAT4 }; // radii
        layout.attrs[5] = .{ .offset = 48, .format = .FLOAT2 }; // border, mode
        layout.attrs[6] = .{ .offset = 56, .format = .UBYTE4N }; // color
        layout.attrs[7] = .{ .offset = 60, .format = .UBYTE4N }; // border color

        self.pipeline = sg.makePipeline(.{
            .shader = self.shader,
            .layout = layout,
            .primitive_type = .TRIANGLES,
            .index_type = .UINT32,
            .cull_mode = .NONE,
            .depth = .{ .compare = .ALWAYS, .write_enabled = false },
            .color_count = 1,
            .colors = init: {
                var colors: @FieldType(sg.PipelineDesc, "colors") = @splat(.{});
                colors[0] = .{
                    .write_mask = .RGBA,
                    .blend = .{
                        .enabled = true,
                        .src_factor_rgb = .ONE,
                        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                        .op_rgb = .ADD,
                        .src_factor_alpha = .ONE,
                        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
                        .op_alpha = .ADD,
                    },
                };
                break :init colors;
            },
            .label = "cui-pipeline",
        });
        if (self.pipeline.id == sg.invalid_id) return error.PipelineCreationFailed;

        self.ensureBuffers(initial_vertex_bytes, initial_index_bytes);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        for (self.textures.items) |*texture| {
            if (!texture.alive) continue;
            self.destroyTextureResources(texture);
        }
        self.textures.deinit(self.allocator);
        self.free_handles.deinit(self.allocator);
        if (self.vertex_buffer.id != sg.invalid_id) sg.destroyBuffer(self.vertex_buffer);
        if (self.index_buffer.id != sg.invalid_id) sg.destroyBuffer(self.index_buffer);
        if (self.pipeline.id != sg.invalid_id) sg.destroyPipeline(self.pipeline);
        if (self.sampler.id != sg.invalid_id) sg.destroySampler(self.sampler);
        if (self.shader.id != sg.invalid_id) sg.destroyShader(self.shader);
        self.* = undefined;
    }

    pub fn iface(self: *Renderer) cui.cui_renderer_iface {
        return .{
            .user = self,
            .texture_create = textureCreate,
            .texture_update = textureUpdate,
            .texture_destroy = textureDestroy,
        };
    }

    // ------------------------------------------------------------------
    // textures
    // ------------------------------------------------------------------

    /// Register an existing sokol view (the display image, a thumbnail).
    /// The view stays owned by the caller.
    pub fn registerView(self: *Renderer, view: sg.View, width: u32, height: u32) !cui.cui_texture {
        const handle = try self.allocTexture();
        const texture = &self.textures.items[handle - 1];
        texture.* = .{
            .alive = true,
            .owned = false,
            .view = view,
            .width = width,
            .height = height,
            .format = cui.CUI_TEXTURE_RGBA8,
        };
        return handle;
    }

    pub fn releaseView(self: *Renderer, handle: cui.cui_texture) void {
        if (handle == 0 or handle > self.textures.items.len) return;
        const texture = &self.textures.items[handle - 1];
        if (!texture.alive or texture.owned) return;
        texture.alive = false;
        texture.view = .{};
        texture.image = .{};
        self.free_handles.append(self.allocator, handle) catch {};
    }

    fn allocTexture(self: *Renderer) !usize {
        if (self.free_handles.pop()) |handle| {
            self.textures.items[handle - 1] = .{};
            return handle;
        }
        try self.textures.append(self.allocator, .{});
        return self.textures.items.len;
    }

    fn bytesPerPixel(format: cui.cui_texture_format) usize {
        return if (format == cui.CUI_TEXTURE_R8) 1 else 4;
    }

    fn textureCreate(
        user: ?*anyopaque,
        width: c_int,
        height: c_int,
        format: cui.cui_texture_format,
        pixels: ?*const anyopaque,
    ) callconv(.c) cui.cui_texture {
        const self: *Renderer = @ptrCast(@alignCast(user orelse return 0));
        if (width <= 0 or height <= 0) return 0;
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        const bpp = bytesPerPixel(format);
        const len = w * h * bpp;

        const cpu = self.allocator.alloc(u8, len) catch return 0;
        @memset(cpu, 0);
        if (pixels) |p| {
            const src: [*]const u8 = @ptrCast(p);
            @memcpy(cpu, src[0..len]);
        }

        const handle = self.allocTexture() catch {
            self.allocator.free(cpu);
            return 0;
        };
        const texture = &self.textures.items[handle - 1];
        texture.* = .{
            .alive = true,
            .owned = true,
            .width = @intCast(w),
            .height = @intCast(h),
            .format = format,
            .cpu = cpu,
        };
        texture.image = makeImage(texture.width, texture.height, texture.format, texture.cpu);
        texture.view = makeView(texture.image);
        return handle;
    }

    fn textureUpdate(
        user: ?*anyopaque,
        handle: cui.cui_texture,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        pixels: ?*const anyopaque,
        stride: c_int,
    ) callconv(.c) void {
        const self: *Renderer = @ptrCast(@alignCast(user orelse return));
        if (handle == 0 or handle > self.textures.items.len) return;
        const texture = &self.textures.items[handle - 1];
        if (!texture.alive or !texture.owned) return;
        const src_ptr = pixels orelse return;
        if (x < 0 or y < 0 or width <= 0 or height <= 0) return;

        const bpp = bytesPerPixel(texture.format);
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        const row_bytes = w * bpp;
        const src_stride: usize = if (stride > 0) @intCast(stride) else row_bytes;
        const src: [*]const u8 = @ptrCast(src_ptr);
        const tex_w: usize = texture.width;

        var row: usize = 0;
        while (row < h) : (row += 1) {
            const dst_y: usize = @as(usize, @intCast(y)) + row;
            if (dst_y >= texture.height) break;
            const dst_off = (dst_y * tex_w + @as(usize, @intCast(x))) * bpp;
            if (dst_off + row_bytes > texture.cpu.len) break;
            @memcpy(texture.cpu[dst_off..][0..row_bytes], src[row * src_stride ..][0..row_bytes]);
        }
        texture.rebuild = true;
    }

    fn textureDestroy(user: ?*anyopaque, handle: cui.cui_texture) callconv(.c) void {
        const self: *Renderer = @ptrCast(@alignCast(user orelse return));
        if (handle == 0 or handle > self.textures.items.len) return;
        const texture = &self.textures.items[handle - 1];
        if (!texture.alive) return;
        self.destroyTextureResources(texture);
        texture.* = .{};
        self.free_handles.append(self.allocator, handle) catch {};
    }

    fn destroyTextureResources(self: *Renderer, texture: *Texture) void {
        // Externally registered views belong to the display texture / catalog;
        // only textures CUI created are ours to destroy.
        if (texture.owned) {
            if (texture.view.id != sg.invalid_id) sg.destroyView(texture.view);
            if (texture.image.id != sg.invalid_id) sg.destroyImage(texture.image);
            if (texture.cpu.len > 0) self.allocator.free(texture.cpu);
        }
        texture.view = .{};
        texture.image = .{};
        texture.cpu = &.{};
        texture.rebuild = false;
    }

    /// CUI updated the atlas during end_frame; rebuild those images before the
    /// render pass starts (sokol resources cannot be created inside a pass).
    pub fn flushTextures(self: *Renderer) void {
        for (self.textures.items) |*texture| {
            if (!texture.alive or !texture.owned or !texture.rebuild) continue;
            const old_view = texture.view;
            const old_image = texture.image;
            texture.image = makeImage(texture.width, texture.height, texture.format, texture.cpu);
            texture.view = makeView(texture.image);
            texture.rebuild = false;
            if (old_view.id != sg.invalid_id) sg.destroyView(old_view);
            if (old_image.id != sg.invalid_id) sg.destroyImage(old_image);
        }
    }

    // ------------------------------------------------------------------
    // frame
    // ------------------------------------------------------------------

    /// Upload the frame's vertices/indices. Must run outside a render pass.
    pub fn prepare(self: *Renderer, draw_data: [*c]const cui.cui_draw_data) void {
        const dd = draw_data orelse return;
        const d = dd.*;
        const vbytes: usize = @as(usize, @intCast(@max(d.vertex_count, 0))) * vertex_stride;
        const ibytes: usize = @as(usize, @intCast(@max(d.index_count, 0))) * @sizeOf(u32);
        self.ensureBuffers(vbytes, ibytes);

        if (vbytes > 0 and d.vertices != null) {
            sg.updateBuffer(self.vertex_buffer, .{ .ptr = d.vertices, .size = vbytes });
        }
        if (ibytes > 0 and d.indices != null) {
            sg.updateBuffer(self.index_buffer, .{ .ptr = d.indices, .size = ibytes });
        }
    }

    /// Draw the frame's commands. Must run inside a render pass.
    pub fn render(self: *Renderer, draw_data: [*c]const cui.cui_draw_data) void {
        const dd = draw_data orelse return;
        const d = dd.*;
        if (d.command_count <= 0 or d.vertex_count <= 0 or d.index_count <= 0) return;
        sg.applyPipeline(self.pipeline);

        var params = shd.VsParams{
            .viewport = .{ @floatFromInt(d.width_px), @floatFromInt(d.height_px) },
        };
        sg.applyUniforms(shd.UB_vs_params, .{ .ptr = &params, .size = @sizeOf(shd.VsParams) });

        const fb_w: f32 = @floatFromInt(d.width_px);
        const fb_h: f32 = @floatFromInt(d.height_px);

        var i: usize = 0;
        const command_count: usize = @intCast(d.command_count);
        while (i < command_count) : (i += 1) {
            const cmd = d.commands[i];
            if (cmd.index_count == 0) continue;

            const clip = cmd.clip;
            const x0 = @max(@as(f32, 0), @floor(clip.x));
            const y0 = @max(@as(f32, 0), @floor(clip.y));
            const x1 = @min(fb_w, @ceil(clip.x + clip.w));
            const y1 = @min(fb_h, @ceil(clip.y + clip.h));
            if (x1 <= x0 or y1 <= y0) continue;

            const handle = if (cmd.texture != 0) cmd.texture else d.font_atlas;
            const tex = self.textureAt(handle) orelse continue;

            const bindings = sg.Bindings{
                .vertex_buffers = init: {
                    var buffers: @FieldType(sg.Bindings, "vertex_buffers") = @splat(.{});
                    buffers[0] = self.vertex_buffer;
                    break :init buffers;
                },
                .index_buffer = self.index_buffer,
                .views = init: {
                    var views: @FieldType(sg.Bindings, "views") = @splat(.{});
                    views[shd.VIEW_tex] = tex.view;
                    break :init views;
                },
                .samplers = init: {
                    var samplers: @FieldType(sg.Bindings, "samplers") = @splat(.{});
                    samplers[shd.SMP_smp] = self.sampler;
                    break :init samplers;
                },
            };
            sg.applyBindings(bindings);
            sg.applyScissorRect(
                @intFromFloat(x0),
                @intFromFloat(y0),
                @intFromFloat(x1 - x0),
                @intFromFloat(y1 - y0),
                true,
            );
            sg.draw(cmd.index_offset, cmd.index_count, 1);
        }
    }

    fn textureAt(self: *Renderer, handle: cui.cui_texture) ?*Texture {
        if (handle == 0 or handle > self.textures.items.len) return null;
        const texture = &self.textures.items[handle - 1];
        if (!texture.alive or texture.view.id == sg.invalid_id) return null;
        return texture;
    }

    fn ensureBuffers(self: *Renderer, vertex_bytes: usize, index_bytes: usize) void {
        if (vertex_bytes > self.vertex_capacity) {
            if (self.vertex_buffer.id != sg.invalid_id) sg.destroyBuffer(self.vertex_buffer);
            self.vertex_capacity = growCapacity(self.vertex_capacity, vertex_bytes, initial_vertex_bytes);
            self.vertex_buffer = sg.makeBuffer(.{
                .size = self.vertex_capacity,
                .usage = .{ .vertex_buffer = true, .dynamic_update = true },
                .label = "cui-vertices",
            });
        }
        if (index_bytes > self.index_capacity) {
            if (self.index_buffer.id != sg.invalid_id) sg.destroyBuffer(self.index_buffer);
            self.index_capacity = growCapacity(self.index_capacity, index_bytes, initial_index_bytes);
            self.index_buffer = sg.makeBuffer(.{
                .size = self.index_capacity,
                .usage = .{ .index_buffer = true, .dynamic_update = true },
                .label = "cui-indices",
            });
        }
    }
};

fn growCapacity(current: usize, needed: usize, initial: usize) usize {
    var cap = @max(current, initial);
    while (cap < needed) cap *= 2;
    return cap;
}

fn makeImage(width: u32, height: u32, format: cui.cui_texture_format, pixels: []const u8) sg.Image {
    var levels: [16]sg.Range = @splat(.{});
    if (pixels.len > 0) levels[0] = sg.asRange(pixels);
    return sg.makeImage(.{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = if (format == cui.CUI_TEXTURE_R8) .R8 else .RGBA8,
        .data = .{ .mip_levels = levels },
        .label = "cui-texture",
    });
}

fn makeView(image: sg.Image) sg.View {
    return sg.makeView(.{
        .texture = .{ .image = image },
        .label = "cui-texture-view",
    });
}
