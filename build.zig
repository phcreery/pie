const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const sokol = @import("sokol");
const cimgui = @import("cimgui");
const spv = @import("build/spirv.zig");

pub fn build(b: *Build) !void { // $ls root_id 1
    // CONFIGURATION
    const target = b.standardTargetOptions(.{});
    // for testing only, forces a native build
    // const target = b.resolveTargetQuery(.{
    //     .ofmt = .c,
    // });
    const optimize = b.standardOptimizeOption(.{});
    const opts = .{ .target = target, .optimize = optimize };

    const opt_docking = b.option(bool, "docking", "Build with docking support") orelse false;

    // Get the matching Zig module name, C header search path and C library for
    // vanilla imgui vs the imgui docking branch.
    const cimgui_conf = cimgui.getConfig(opt_docking);

    // DEPENDENCIES
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .wgpu = true,
        .wgpu_native = true,
        .with_sokol_imgui = true,
        .dynamic_linkage = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
        .dynamic_linkage = true,
    });
    // Image decoding is the hot path. C dependencies (libraw, stb_image) honor
    // their own optimize; a Zig *module* dependency does not (Zig compiles
    // imported modules at the root artifact's optimize level).
    const dep_opts_fast = .{ .target = target, .optimize = .ReleaseFast };
    const dep_libraw = b.dependency("libraw", dep_opts_fast);
    // native folder chooser; the package compiles the C library for the target
    const dep_nfd = b.dependency("nativefiledialog_extended", opts);
    const dep_wgpu_zig = b.dependency("wgpu-zig", .{});
    const dep_zigimg = b.dependency("zigimg", dep_opts_fast);
    const dep_zbench = b.dependency("zbench", opts);
    const dep_zuballoc = b.dependency("zuballoc", opts);
    // const dep_zmath = b.dependency("zmath", opts);

    // inject the cimgui header search path into the sokol C library compile step
    const mod_sokol_clib = dep_sokol.artifact("sokol_clib").root_module;
    mod_sokol_clib.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));
    @import("wgpu-zig").addWgpuNativeObjectFiles(b, mod_sokol_clib, target, optimize);
    // sokol's ImGui glue calls into Dear ImGui, so as a shared library it has
    // to record that dependency itself, and resolve its siblings relative to
    // its own location (it is installed next to them in zig-out/lib).
    mod_sokol_clib.linkLibrary(dep_cimgui.artifact(cimgui_conf.clib_name));
    mod_sokol_clib.addRPathSpecial("$ORIGIN");

    // OPTIONS
    const mod_options = b.addOptions();
    const build_date = std.Io.Timestamp.now(b.graph.io, std.Io.Clock.real).toSeconds();
    mod_options.addOption(i64, "timestamp", build_date);
    mod_options.addOption(bool, "docking", opt_docking);

    // Shaders (for UI)
    // https://github.com/floooh/pacman.zig/blob/main/build.zig
    // extract the sokol module and shdc dependency from sokol dependency
    const mod_sokol = dep_sokol.module("sokol");
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    const mod_texview_shd = try sokol.shdc.createModule(b, "texview_shader", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "src/gui/texview.glsl",
        .output = "texview.zig",
        .slang = .{ .wgsl = true },
    });

    // TYPES MODULE
    const mod_types = b.createModule(.{
        .root_source_file = b.path("src/types/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    // MATH MODULE
    const mod_math = b.createModule(.{
        .root_source_file = b.path("src/math/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    // CONSOLE MODULE
    const mod_console = b.createModule(.{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    // GPU MODULE
    const mod_gpu = b.createModule(.{
        .root_source_file = b.path("src/gpu/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wgpu_zig", .module = dep_wgpu_zig.module("wgpu") },
            .{ .name = "types", .module = mod_types },
            .{ .name = "zuballoc", .module = dep_zuballoc.module("zuballoc") },
        },
    });

    // STBI MODULE
    const mod_stbi_core = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    mod_stbi_core.addIncludePath(b.path("src/stbi"));
    mod_stbi_core.addCSourceFile(.{
        .file = b.path("src/stbi/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    const lib_stbi = b.addLibrary(.{
        .name = "stbi",
        .linkage = .static,
        .root_module = mod_stbi_core,
    });
    const mod_stbi = b.createModule(.{
        .root_source_file = b.path("src/stbi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_stbi.linkLibrary(lib_stbi);

    // PIE MODULE
    const mod_pie = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "console", .module = mod_console },
            .{ .name = "gpu", .module = mod_gpu },
            .{ .name = "types", .module = mod_types },
            .{ .name = "math", .module = mod_math },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "stbi", .module = mod_stbi },
        },
    });

    // DEFAULT PIPELINE GRAPHS
    // `graphs.zig` builds its recommended pipelines by deserializing these
    // assets (one per `i-*` family, named after it), so they are compiled into
    // the module. Adding a decoder means adding an asset and a table row there,
    // plus the import below.
    mod_pie.addAnonymousImport("default.i-raw.graph", .{ .root_source_file = b.path("assets/default.i-raw.graph") });
    mod_pie.addAnonymousImport("default.i-png.graph", .{ .root_source_file = b.path("assets/default.i-png.graph") });

    // PIE MODULES SPIR-V SHADERS
    try spv.compileAndEmbedZigSpirVModules(
        b,
        mod_pie,
        optimize,
        @import("src/engine/modules/modules.zon"),
        &.{
            .{ .name = "math", .module = mod_math },
            .{ .name = "types", .module = mod_types },
        },
    );

    // NFD MODULE
    // Native folder chooser; the module links the vendored C library so
    // importers only need `@import("nfd")`.
    const mod_nfd = b.createModule(.{
        .root_source_file = b.path("src/nfd/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{},
    });
    mod_nfd.linkLibrary(dep_nfd.artifact("nfd"));

    // SESSION MODULE
    const mod_session = b.createModule(.{
        .root_source_file = b.path("src/app/session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "types", .module = mod_types },
            .{ .name = "texview_shader", .module = mod_texview_shd },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "nfd", .module = mod_nfd },
        },
    });

    // GUI MODULE
    const mod_gui = b.createModule(.{
        .root_source_file = b.path("src/gui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session", .module = mod_session },
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "types", .module = mod_types },
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });

    // wgpu-native ships prebuilt as a shared library. Install it beside the exe
    // so the exe resolves it through its `$ORIGIN/../lib` rpath instead of a
    // cwd-relative path into the package cache.
    const wgpu_bin_dep_name = b.fmt("wgpu_{s}_{s}_{s}_{s}", .{
        @tagName(target.result.os.tag),
        @tagName(target.result.cpu.arch),
        if (target.result.os.tag == .linux) "none" else @tagName(target.result.abi),
        if (optimize == .debug) "debug" else "release",
    });
    const wgpu_lib_name = switch (target.result.os.tag) {
        .windows => "wgpu_native.dll",
        .macos => "libwgpu_native.dylib",
        else => "libwgpu_native.so",
    };
    if (b.lazyDependency(wgpu_bin_dep_name, .{})) |wgpu_bin| {
        const install_wgpu = b.addInstallFileWithDir(
            wgpu_bin.path(b.fmt("lib/{s}", .{wgpu_lib_name})),
            .lib,
            wgpu_lib_name,
        );
        b.getInstallStep().dependOn(&install_wgpu.step);
    }

    // APP MODULE
    const mod_app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Host side: owns the session the GUI draws from.
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "session", .module = mod_session },
            .{ .name = "gui", .module = mod_gui },
            .{ .name = "console", .module = mod_console },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "gpu", .module = mod_gpu },
            .{ .name = "wgpu_zig", .module = dep_wgpu_zig.module("wgpu") },
        },
    });
    mod_app.addOptions("build_options", mod_options);

    // TESTS
    // UNIT TESTS
    const unit_tests = b.addTest(.{
        .name = "unit tests",
        .use_llvm = true,
        .root_module = mod_pie,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `math` is a module dependency, so its tests are not collected by the
    // mod_pie artifact above and need one of their own.
    const math_unit_tests = b.addTest(.{
        .name = "math unit tests",
        .use_llvm = true,
        .root_module = mod_math,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_math_unit_tests = b.addRunArtifact(math_unit_tests);
    test_step.dependOn(&run_math_unit_tests.step);

    // INTEGRATION TESTS
    // first run the zig code as an executable
    const mod_integration = b.createModule(.{
        .root_source_file = b.path("testing/integration/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "console", .module = mod_console },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "zbench", .module = dep_zbench.module("zbench") },
            .{ .name = "stbi", .module = mod_stbi },
        },
    });

    const integration_tests = b.addTest(.{
        .name = "integration tests",
        .use_llvm = true,
        .root_module = mod_integration,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    // const install_integration_tests = b.addInstallArtifact(integration_tests, .{});
    // run_integration_tests.step.dependOn(&install_integration_tests.step);

    const integration_test_step = b.step("integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Force the test runner to wait until everything is installed in zig-out/
    // integration_test_step.dependOn(b.getInstallStep());

    // from here on different handling for native vs wasm builds
    // if (target.result.cpu.arch.isWasm()) {
    //     try buildWasm(b, .{
    //         .mod_main = mod_app,
    //         .dep_sokol = dep_sokol,
    //         .dep_cimgui = dep_cimgui,
    //         .cimgui_clib_name = cimgui_conf.clib_name,
    //     });
    // } else {
    try buildNative(b, mod_app);
}

fn buildNative(b: *Build, mod: *Build.Module) !void {
    const exe = b.addExecutable(.{
        .name = "pie",
        .root_module = mod,
        .use_llvm = true,
    });
    // The shared C libraries (sokol, Dear ImGui, wgpu-native) live in
    // zig-out/lib, so resolve them relative to the exe.
    exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    b.installArtifact(exe);
    const exe_step = b.step("app", "Run pie app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    exe_step.dependOn(&run_cmd.step);
}

const BuildWasmOptions = struct {
    mod_main: *Build.Module,
    dep_sokol: *Build.Dependency,
    dep_cimgui: *Build.Dependency,
    cimgui_clib_name: []const u8,
};

// https://github.com/floooh/sokol-zig-imgui-sample/blob/main/build.zig
fn buildWasm(b: *Build, opts: BuildWasmOptions) !void {
    // build the main file into a library, this is because the WASM 'exe'
    // needs to be linked in a separate build step with the Emscripten linker
    const demo = b.addLibrary(.{
        .name = "demo",
        .root_module = opts.mod_main,
    });

    // get the Emscripten SDK dependency from the sokol dependency
    const dep_emsdk = opts.dep_sokol.builder.dependency("emsdk", .{});

    // need to inject the Emscripten system header include path into
    // the cimgui C library otherwise the C/C++ code won't find
    // C stdlib headers
    const emsdk_incl_path = dep_emsdk.path("upstream/emscripten/cache/sysroot/include");
    opts.dep_cimgui.artifact(opts.cimgui_clib_name).root_module.addSystemIncludePath(emsdk_incl_path);

    // all C libraries need to depend on the sokol library, when building for
    // WASM this makes sure that the Emscripten SDK has been setup before
    // C compilation is attempted (since the sokol C library depends on the
    // Emscripten SDK setup step)
    opts.dep_cimgui.artifact(opts.cimgui_clib_name).step.dependOn(&opts.dep_sokol.artifact("sokol_clib").step);

    // create a build step which invokes the Emscripten linker
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = demo,
        .target = opts.mod_main.resolved_target.?,
        .optimize = opts.mod_main.optimize.?,
        .emsdk = dep_emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = b.path("src/web/shell.html"),
    });
    // attach to default target
    b.getInstallStep().dependOn(&link_step.step);
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "pie", .emsdk = dep_emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run pie").dependOn(&run.step);
}
