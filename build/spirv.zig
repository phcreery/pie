const std = @import("std");
const builtin = @import("builtin");

pub fn compileZigToSpirv(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    file: std.Build.LazyPath,
    comptime features: []const std.Target.spirv.Feature,
) std.Build.LazyPath {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.generic },
        .cpu_features_add = std.Target.spirv.featureSet([_]std.Target.spirv.Feature{.v1_1} ++ features),
        .os_tag = .vulkan,
        .ofmt = .spirv,
    });
    const mod_spirv = b.createModule(.{
        .root_source_file = b.path("src/engine/modules/spirv.zig"),
        .target = target,
        .optimize = optimize,
    });
    const obj = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = file,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spirv", .module = mod_spirv },
            },
        }),
        .use_llvm = false,
        .use_lld = false,
    });
    return obj.getEmittedBin();
}

/// Run the naga-compatibility patcher (see spirv_naga_patch.zig) over the
/// SPIR-V emitted by the Zig compiler and return the patched binary.
fn patchSpirvForNaga(
    b: *std.Build,
    obj: std.Build.LazyPath,
    file_name: []const u8,
) !std.Build.LazyPath {
    const patcher = b.addExecutable(.{
        .name = "spirv-naga-patch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/spirv_naga_patch.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(patcher);
    run.addFileArg(obj);
    var buf: [64]u8 = undefined;
    const output_file_name = try std.fmt.bufPrint(&buf, "{s}.patched.spv", .{file_name});
    return run.addOutputFileArg(output_file_name);
}

pub fn compileAndEmbedModuleSpirVShader(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    module_name: []const u8,
    file_name: []const u8,
    embed_name: []const u8,
) !void {
    var buffer: [64]u8 = undefined;
    const file_path_str = try std.fmt.bufPrint(&buffer, "src/engine/modules/{s}/{s}", .{ module_name, file_name });
    const file_name_path = b.path(file_path_str);
    const spv = compileZigToSpirv(b, optimize, file_name, file_name_path, &[_]std.Target.spirv.Feature{});
    const spv_patched = try patchSpirvForNaga(b, spv, file_name);
    mod.addAnonymousImport(embed_name, .{ .root_source_file = spv_patched });
}

pub fn compileAndEmbedZigSpirVModules(b: *std.Build, mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) !void {
    try compileAndEmbedModuleSpirVShader(b, optimize, mod, "test-nop-zig", "nop.comp.zig", "nop.comp.zig.spv.embed");
}
