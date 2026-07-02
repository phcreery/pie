const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const sokol = @import("sokol");
const cimgui = @import("cimgui");

pub fn build(b: *Build) !void {
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
    // note that the sokol dependency is built with `.with_sokol_imgui = true`
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .wgpu = true,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", opts);
    const dep_zdt = b.dependency("zdt", opts);
    const dep_libraw = b.dependency("libraw", opts);
    // const dep_wgpu_native = b.dependency("wgpu_native_zig", opts);
    const dep_zgpu = b.dependency("zgpu", opts);
    const dep_zigimg = b.dependency("zigimg", opts);
    const dep_zbench = b.dependency("zbench", opts);
    const dep_zuballoc = b.dependency("zuballoc", opts);

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));
    // inject the webgpu/webgpu.h headers from zgpu
    @import("zgpu").addDawnPaths(b, dep_sokol.artifact("sokol_clib").root_module, target.result);

    // OPTIONS
    const mod_options = b.addOptions();
    mod_options.addOption(
        i64,
        "timestamp",
        std.Io.Timestamp.now(b.graph.io, std.Io.Clock.real).toSeconds(),
    );
    mod_options.addOption(bool, "docking", opt_docking);

    // CONSOLE MODULE
    const mod_console = b.createModule(.{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    // PIE MODULE
    // main module with sokol and cimgui imports
    const mod_pie = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "console", .module = mod_console },
            .{ .name = "zdt", .module = dep_zdt.module("zdt") },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "wgpu_dawn", .module = dep_zgpu.module("wgpu") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "zuballoc", .module = dep_zuballoc.module("zuballoc") },
        },
    });
    mod_pie.linkLibrary(dep_zgpu.artifact("zdawn"));

    // APP MODULE
    // main module with sokol and cimgui imports
    const mod_app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "console", .module = mod_console },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            .{ .name = "zdt", .module = dep_zdt.module("zdt") },
            // .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "wgpu_dawn", .module = dep_zgpu.module("wgpu") },
        },
    });
    mod_app.addOptions("build_options", mod_options);

    // Link the zdawn C/C++ wrapper artifact.
    // this is our link to webgpu_dawn (libwebgpu_dawn.a)
    mod_app.linkLibrary(dep_zgpu.artifact("zdawn"));

    // TESTS
    // UNIT TESTS
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .name = "unit tests",
        .root_module = mod_app,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // INTEGRATION
    // first run the zig code as an executable
    const mod_integration = b.createModule(.{
        .root_source_file = b.path("testing/integration/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // .{ .name = "app", .module = mod_app },
            .{ .name = "pie", .module = mod_pie },
            .{ .name = "console", .module = mod_console },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
            .{ .name = "zigimg", .module = dep_zigimg.module("zigimg") },
            .{ .name = "zbench", .module = dep_zbench.module("zbench") },
        },
    });

    // INTEGRATION TESTS
    const integration_test_step = b.step("integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .name = "integration tests",
        .root_module = mod_integration,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_test_step.dependOn(&run_integration_tests.step);

    // from here on different handling for native vs wasm builds
    if (target.result.cpu.arch.isWasm()) {
        try buildWasm(b, .{
            .mod_main = mod_app,
            .dep_sokol = dep_sokol,
            .dep_cimgui = dep_cimgui,
            .cimgui_clib_name = cimgui_conf.clib_name,
        });
    } else {
        try buildNative(b, mod_app);
    }
}

fn buildNative(b: *Build, mod: *Build.Module) !void {
    const exe = b.addExecutable(.{
        .name = "pie",
        .root_module = mod,
    });
    if (builtin.os.tag == .windows) {
        // zig does not include System32 in the default library search path
        // so we need to add it manually here
        // https://github.com/ziglang/zig/blob/ddc815e3d88d32b8f3df0610ee59c8d34b8ff8eb/lib/std/zig/system/NativePaths.zig#L130
        const system_library_path: std.Build.LazyPath = .{ .cwd_relative = "C:\\Windows\\System32" };
        exe.root_module.addLibraryPath(system_library_path);
    }
    // Link zgpu's zdawn artifact (which links libwebgpu_dawn.a + system
    // frameworks) so the wgpu C procs resolve at link time.
    @import("zgpu").addLibraryPathsTo(exe);
    @import("zgpu").linkSystemDeps(b, exe);
    b.installArtifact(exe);
    b.step("run", "Run pie").dependOn(&b.addRunArtifact(exe).step);
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
