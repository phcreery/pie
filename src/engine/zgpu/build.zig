const std = @import("std");
const log = std.log.scoped(.zgpu);

const default_options = struct {
    const uniforms_buffer_size = 4 * 1024 * 1024;
    const dawn_skip_validation = false;
    const dawn_allow_unsafe_apis = false;
    const buffer_pool_size = 256;
    const texture_pool_size = 256;
    const texture_view_pool_size = 256;
    const sampler_pool_size = 16;
    const render_pipeline_pool_size = 128;
    const compute_pipeline_pool_size = 128;
    const bind_group_pool_size = 32;
    const bind_group_layout_pool_size = 32;
    const pipeline_layout_pool_size = 32;
    const max_num_bindings_per_group = 10;
    const max_num_bind_groups_per_pipeline = 4;
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .uniforms_buffer_size = b.option(
            u64,
            "uniforms_buffer_size",
            "Set uniforms buffer size",
        ) orelse default_options.uniforms_buffer_size,
        .dawn_skip_validation = b.option(
            bool,
            "dawn_skip_validation",
            "Disable Dawn validation",
        ) orelse default_options.dawn_skip_validation,
        .dawn_allow_unsafe_apis = b.option(
            bool,
            "dawn_allow_unsafe_apis",
            "Allow unsafe WebGPU APIs (e.g. timestamp queries)",
        ) orelse default_options.dawn_allow_unsafe_apis,
        .buffer_pool_size = b.option(
            u32,
            "buffer_pool_size",
            "Set buffer pool size",
        ) orelse default_options.buffer_pool_size,
        .texture_pool_size = b.option(
            u32,
            "texture_pool_size",
            "Set texture pool size",
        ) orelse default_options.texture_pool_size,
        .texture_view_pool_size = b.option(
            u32,
            "texture_view_pool_size",
            "Set texture view pool size",
        ) orelse default_options.texture_view_pool_size,
        .sampler_pool_size = b.option(
            u32,
            "sampler_pool_size",
            "Set sample pool size",
        ) orelse default_options.sampler_pool_size,
        .render_pipeline_pool_size = b.option(
            u32,
            "render_pipeline_pool_size",
            "Set render pipeline pool size",
        ) orelse default_options.render_pipeline_pool_size,
        .compute_pipeline_pool_size = b.option(
            u32,
            "compute_pipeline_pool_size",
            "Set compute pipeline pool size",
        ) orelse default_options.compute_pipeline_pool_size,
        .bind_group_pool_size = b.option(
            u32,
            "bind_group_pool_size",
            "Set bind group pool size",
        ) orelse default_options.bind_group_pool_size,
        .bind_group_layout_pool_size = b.option(
            u32,
            "bind_group_layout_pool_size",
            "Set bind group layout pool size",
        ) orelse default_options.bind_group_layout_pool_size,
        .pipeline_layout_pool_size = b.option(
            u32,
            "pipeline_layout_pool_size",
            "Set pipeline layout pool size",
        ) orelse default_options.pipeline_layout_pool_size,
        .max_num_bindings_per_group = b.option(
            u32,
            "max_num_bindings_per_group",
            "Set maximum number of bindings per bind group",
        ) orelse default_options.max_num_bindings_per_group,
        .max_num_bind_groups_per_pipeline = b.option(
            u32,
            "max_num_bind_groups_per_pipeline",
            "Set maximum number of bindings groups per pipeline",
        ) orelse default_options.max_num_bind_groups_per_pipeline,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }

    const options_module = options_step.createModule();

    const root = b.addModule("root", .{
        .root_source_file = b.path("src/zgpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zgpu_options", .module = options_module },
            .{ .name = "zpool", .module = b.dependency("zpool", .{}).module("root") },
        },
    });
    // zgpu.zig / wgpu.zig do @cImport(@cInclude("webgpu/webgpu.h")); pull
    // the header (and the lib path) from the downloaded dawn prebuilt dep.
    addDawnPaths(b, root, target.result);

    // Standalone `wgpu` module: just the hand-written webgpu.h bindings
    // (src/wgpu.zig) + the dawn include path. Deliberately does NOT import
    // zpool (which is required only by zgpu.zig's GraphicsContext and is
    // currently incompatible with Zig 0.16's @Type removal). Consumers that
    // only need the raw wgpu C bindings can import this module directly.
    const wgpu_mod = b.addModule("wgpu", .{
        .root_source_file = b.path("src/wgpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDawnPaths(b, wgpu_mod, target.result);

    const zdawn = b.addLibrary(.{
        .name = "zdawn",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zdawn.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(zdawn);
    linkSystemDeps(b, zdawn);
    addDawnPaths(b, zdawn.root_module, zdawn.rootModuleTarget());

    // prebuilt libs from os-specific dependency
    zdawn.root_module.linkSystemLibrary("webgpu_dawn", .{});
    if (zdawn.rootModuleTarget().os.tag == .windows) zdawn.root_module.linkSystemLibrary("mingw_helpers", .{});

    zdawn.root_module.link_libc = true;
    zdawn.root_module.link_libcpp = true;
    zdawn.root_module.addIncludePath(b.path("src"));

    const test_step = b.step("test", "Run zgpu tests");
    const tests = b.addTest(.{
        .name = "zgpu-tests",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zgpu.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkLibrary(zdawn);
    linkSystemDeps(b, tests);
    addDawnPaths(b, tests.root_module, tests.rootModuleTarget());
    b.installArtifact(tests);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Call this for your exe to copy dxcompiler.dll and dxil.dll to your exe's directory from zwindows
pub fn installDxcFrom(exe: *std.Build.Step.Compile, zwindows_dep_name: []const u8) void {
    const b = exe.step.owner;
    exe.step.dependOn(
        &b.addInstallFileWithDir(
            .{ .dependency = .{
                .dependency = b.dependency(zwindows_dep_name, .{}),
                .sub_path = "bin/x64/dxcompiler.dll",
            } },
            .bin,
            "dxcompiler.dll",
        ).step,
    );
    exe.step.dependOn(
        &b.addInstallFileWithDir(
            .{ .dependency = .{
                .dependency = b.dependency(zwindows_dep_name, .{}),
                .sub_path = "bin/x64/dxil.dll",
            } },
            .bin,
            "dxil.dll",
        ).step,
    );
}

pub fn linkSystemDeps(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const m = compile_step.root_module;
    switch (compile_step.rootModuleTarget().os.tag) {
        .windows => {
            if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
                m.addLibraryPath(system_sdk.path("windows/lib/x86_64-windows-gnu"));
            }
            m.linkSystemLibrary("ole32", .{});
            m.linkSystemLibrary("oleaut32", .{});
            m.linkSystemLibrary("dxguid", .{});
            m.linkSystemLibrary("dbghelp", .{});
        },
        .macos => {
            // NOTE: we intentionally do NOT use system_sdk's macos12 stub
            // frameworks here. The Google dawn prebuilt was built against a
            // recent macOS SDK and references Metal classes introduced in
            // macOS 15.2+ (e.g. MTLLogStateDescriptor), which are absent from
            // the macOS 12 stub Metal.framework. For native builds the host
            // SDK's frameworks are correct and newer, so link directly.
            // CoreFoundation is required by dawn's IOSurfaceUtils/PhysicalDeviceMTL.
            m.linkSystemLibrary("objc", .{});
            m.linkFramework("Metal", .{});
            m.linkFramework("CoreGraphics", .{});
            m.linkFramework("CoreFoundation", .{});
            m.linkFramework("Foundation", .{});
            m.linkFramework("IOKit", .{});
            m.linkFramework("IOSurface", .{});
            m.linkFramework("QuartzCore", .{});
        },
        else => {},
    }
}

/// Resolve the os/arch-specific dawn prebuilt dependency for `target` and add
/// both its library path (`lib/` or root) and its header path (`include/`)
/// to `m`. Used by the zgpu `root` module (which @cImports webgpu/webgpu.h)
/// and the `zdawn`/test artifacts.
pub fn addDawnPaths(b: *std.Build, m: *std.Build.Module, target: std.Target) void {
    switch (target.os.tag) {
        .windows => {
            if (b.lazyDependency("zdawn_x86_64_windows_gnu", .{})) |dawn_prebuilt| {
                m.addLibraryPath(dawn_prebuilt.path(""));
                m.addIncludePath(dawn_prebuilt.path("include"));
            }
        },
        .linux => {
            if (target.cpu.arch.isX86()) {
                if (b.lazyDependency("zdawn_x86_64_linux_gnu", .{})) |dawn_prebuilt| {
                    m.addLibraryPath(dawn_prebuilt.path(""));
                    m.addIncludePath(dawn_prebuilt.path("include"));
                }
            } else if (target.cpu.arch.isAARCH64()) {
                if (b.lazyDependency("dawn_aarch64_linux_gnu", .{})) |dawn_prebuilt| {
                    m.addLibraryPath(dawn_prebuilt.path(""));
                    m.addIncludePath(dawn_prebuilt.path("include"));
                }
            }
        },
        .macos => {
            // Google dawn prebuilt lays out its archive as lib/libwebgpu_dawn.a
            // and ships headers under include/webgpu/webgpu.h (+ dawn/webgpu.h).
            if (target.cpu.arch.isX86()) {
                if (b.lazyDependency("dawn_x86_64_macos", .{})) |dawn_prebuilt| {
                    m.addLibraryPath(dawn_prebuilt.path("lib"));
                    m.addIncludePath(dawn_prebuilt.path("include"));
                }
            } else if (target.cpu.arch.isAARCH64()) {
                if (b.lazyDependency("dawn_aarch64_macos", .{})) |dawn_prebuilt| {
                    m.addLibraryPath(dawn_prebuilt.path("lib"));
                    m.addIncludePath(dawn_prebuilt.path("include"));
                }
            }
        },
        else => {},
    }
}

/// Backwards-compatible wrapper: adds the dawn lib + include paths to a
/// `Compile` step's root module.
pub fn addLibraryPathsTo(compile_step: *std.Build.Step.Compile) void {
    const b = compile_step.step.owner;
    addDawnPaths(b, compile_step.root_module, compile_step.rootModuleTarget());
}

pub fn checkTargetSupported(target: std.Target) bool {
    const supported = switch (target.os.tag) {
        .windows => target.cpu.arch.isX86() and target.abi.isGnu(),
        .linux => (target.cpu.arch.isX86() or target.cpu.arch.isAARCH64()) and target.abi.isGnu(),
        .macos => blk: {
            if (!target.cpu.arch.isX86() and !target.cpu.arch.isAARCH64()) break :blk false;

            // If min. target macOS version is lesser than the min version we have available, then
            // our Dawn binary is incompatible with the target.
            if (target.os.version_range.semver.min.order(
                .{ .major = 12, .minor = 0, .patch = 0 },
            ) == .lt) break :blk false;
            break :blk true;
        },
        else => false,
    };
    if (supported == false) {
        log.warn("\n" ++
            \\---------------------------------------------------------------------------
            \\
            \\Dawn/WebGPU binary for this target is not available.
            \\
            \\Following targets are supported:
            \\
            \\x86_64-windows-gnu
            \\x86_64-linux-gnu
            \\x86_64-macos.12.0.0-none
            \\aarch64-linux-gnu
            \\aarch64-macos.12.0.0-none
            \\
            \\---------------------------------------------------------------------------
            \\
        , .{});
    }
    return supported;
}
