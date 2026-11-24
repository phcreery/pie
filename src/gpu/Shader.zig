const std = @import("std");
const wgpu = @import("wgpu_zig");
const GPU = @import("GPU.zig");

const slog = std.log.scoped(.gpu);

shader_module: wgpu.ShaderModule,

const Self = @This();

pub const ShaderLanguage = enum {
    wgsl,
    spirv,
    glsl,
};

pub const ShaderSource = union(ShaderLanguage) {
    wgsl: []const u8,
    spirv: []const u8,
    glsl: []const u8,
};

pub const ShaderSourceContext = struct {
    pub fn hash(self: ShaderSourceContext, key: ShaderSource) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        // Hash the active language tag first
        const tag = @as(ShaderLanguage, key);
        hasher.update(std.mem.asBytes(&tag));

        // Safely hash the slice contents based on active variant
        switch (key) {
            .wgsl => |code| hasher.update(code),
            .glsl => |code| hasher.update(code),
            .spirv => |words| {
                // Cast the u32 slice safely to a byte slice for the hasher
                const bytes = std.mem.sliceAsBytes(words);
                hasher.update(bytes);
            },
        }
        return hasher.final();
    }

    pub fn eql(self: ShaderSourceContext, a: ShaderSource, b: ShaderSource) bool {
        _ = self;
        // Verify they are the same language variant
        const tag_a = @as(ShaderLanguage, a);
        const tag_b = @as(ShaderLanguage, b);
        if (tag_a != tag_b) return false;

        // Perform a deep content equality check on the slices
        return switch (a) {
            .wgsl => std.mem.eql(u8, a.wgsl, b.wgsl),
            .glsl => std.mem.eql(u8, a.glsl, b.glsl),
            .spirv => std.mem.eql(u8, a.spirv, b.spirv),
        };
    }
};

/// Cache of compiled shader modules keyed by their source, so identical
/// shaders are only compiled once. Owned by GPU.
pub const ShaderMap = std.HashMap(
    ShaderSource,
    Self,
    ShaderSourceContext,
    std.hash_map.default_max_load_percentage,
);

pub fn compile(gpu: *GPU, shader_source: ShaderSource) !Self {
    slog.debug("Compiling shader", .{});
    const shader_module = switch (shader_source) {
        .wgsl => |code| try gpu.device.createShaderModule(.{ .wgsl = code }),
        .glsl => |code| try gpu.device.createShaderModule(.{ .glsl = .{ .code = code, .stage = .compute } }),
        .spirv => |code| blk: {
            if (code.len == 0 or code.len % @sizeOf(u32) != 0) return error.InvalidSpirvLength;
            // SPIR-V is an array of u32 words, but the source bytes may only
            // be 1-byte aligned (@embedFile guarantees no more, and file reads
            // can return unaligned buffers), so copy into aligned memory that
            // lives for the duration of this call.
            const words = std.heap.page_allocator.alloc(u32, code.len / @sizeOf(u32)) catch return error.OutOfMemory;
            defer std.heap.page_allocator.free(words);
            @memcpy(std.mem.sliceAsBytes(words), code);
            break :blk try gpu.device.createShaderModule(.{
                .spirv = .{ .code = words, .method = .@"chained-source" },
            });
        },
    };

    return Self{
        .shader_module = shader_module,
    };
}

pub fn deinit(self: *Self) void {
    self.shader_module.deinit();
}
