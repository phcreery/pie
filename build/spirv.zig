const std = @import("std");
const builtin = @import("builtin");

pub fn compileZigToSpirv(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    file: std.Build.LazyPath,
    comptime features: []const std.Target.spirv.Feature,
) *std.Build.Step.Compile {
    // _ = features;

    // const target = b.resolveTargetQuery(.{
    //     .cpu_arch = .spirv32,
    //     .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
    //     .os_tag = .vulkan,
    // });
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.generic },
        .cpu_features_add = std.Target.spirv.featureSet([_]std.Target.spirv.Feature{.v1_1} ++ features),
        .os_tag = .vulkan,
        .ofmt = .spirv,
    });
    const obj = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = file,
            .optimize = optimize,
            .target = target,
        }),
        .use_llvm = false,
        .use_lld = false,
    });
    return obj;
}

pub fn embedObject(
    b: *std.Build,
    mod: *std.Build.Module,
    obj: *std.Build.Step.Compile,
    name: []const u8,
    dir: []const u8,
) void {
    const install_obj = b.addInstallArtifact(obj, .{ .dest_dir = .{ .override = .{ .custom = dir } } });
    b.getInstallStep().dependOn(&install_obj.step);

    // b.installArtifact(obj);
    // const spirv = obj.getEmittedBin();
    // _ = b.addInstallBinFile(spirv, "out");

    mod.addAnonymousImport(name, .{ .root_source_file = obj.getEmittedBin() });
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
    embedObject(b, mod, spv, embed_name, "shaders");
}

pub fn compileAndEmbedZigSpirVModules(b: *std.Build, mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) !void {
    try compileAndEmbedModuleSpirVShader(b, optimize, mod, "test-nop-zig", "nop.comp.zig", "nop.comp.zig.embed");
}
