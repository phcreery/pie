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
    // sokol + Dear ImGui are built as shared libraries because the GUI is a
    // hot-reloadable plugin: the exe and the plugin must bind to ONE instance
    // of the sokol/ImGui state (two copies would mean two ImGui contexts).
    // wgpu-native already ships as a shared library.
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
    // Image decoding is the hot path (a debug-built libraw decodes a 24 MP raw
    // several times slower), so these two are built optimized while the app
    // itself stays debug.
    const dep_opts_fast = .{ .target = target, .optimize = .ReleaseFast };
    const dep_libraw = b.dependency("libraw", dep_opts_fast);
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
        },
    });

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

    // ABI MODULE (shared by the host exe and the GUI plugin). Its contract
    // imports the shared parameter vocabulary (`types/ui.zig`) so the engine and
    // the editor describe a control exactly once.
    const mod_abi = b.createModule(.{
        .root_source_file = b.path("src/gui_abi/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = mod_types },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });

    // GUI MODULE
    const mod_gui = b.createModule(.{
        .root_source_file = b.path("src/gui/root.zig"),
        .target = target,
        .optimize = optimize,
        // The plugin is deliberately engine-free (it only draws widgets), so
        // it needs neither `pie` nor the shader bindings. Every declared module
        // root gets parsed, so keep this list minimal.
        .imports = &.{
            .{ .name = "abi", .module = mod_abi },
            .{ .name = "types", .module = mod_types },
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });

    // GUI PLUGIN (hot-reloadable)
    // The exe never links this module: it loads `zig-out/lib/libgui.so` at
    // runtime (see `src/app/plugin.zig`). The plugin borrows the exe's sokol,
    // ImGui and wgpu instances through the shared C libraries above.
    const gui_dl = b.addLibrary(.{
        .name = "gui",
        .linkage = .dynamic,
        .root_module = mod_gui,
        // Matches the exe. The self-hosted backend also compiles and runs this
        // plugin (~15% faster), but backend choice is the small lever here:
        // semantic analysis dominates, so the win comes from shrinking what the
        // plugin reaches. See README "GUI hot reload".
        .use_llvm = true,
    });
    // resolve libsokol_clib.so / libcimgui_clib.so relative to the plugin
    gui_dl.root_module.addRPathSpecial("$ORIGIN");
    const install_gui_dl = b.addInstallArtifact(gui_dl, .{});
    b.getInstallStep().dependOn(&install_gui_dl.step);
    const gui_step = b.step("gui", "Build the hot-reloadable GUI plugin (zig-out/lib/libgui.so)");
    gui_step.dependOn(&install_gui_dl.step);

    // wgpu-native ships prebuilt as a shared library. Install it beside the exe
    // and the plugin so both resolve it through their `$ORIGIN` rpaths instead
    // of a cwd-relative path into the package cache.
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
        gui_step.dependOn(&install_wgpu.step);
    }

    // APP MODULE
    const mod_app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Host side: owns the session (pipeline + blit) the plugin draws from.
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "abi", .module = mod_abi },
            .{ .name = "console", .module = mod_console },
            .{ .name = "texview_shader", .module = mod_texview_shd },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            // .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
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
