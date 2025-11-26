const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Dependency = Build.Dependency;
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

    const opt_docking = b.option(bool, "docking", "Build with docking support") orelse false;
    const ztracy_options = .{
        .enable_ztracy = b.option(
            bool,
            "enable_ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .enable_fibers = b.option(
            bool,
            "enable_fibers",
            "Enable Tracy fiber support",
        ) orelse false,
        .on_demand = b.option(
            bool,
            "on_demand",
            "Build tracy with TRACY_ON_DEMAND",
        ) orelse false,
    };

    // Get the matching Zig module name, C header search path and C library for
    // vanilla imgui vs the imgui docking branch.
    const cimgui_conf = cimgui.getConfig(opt_docking);

    // DEPENDENCIES
    // note that the sokol dependency is built with `.with_sokol_imgui = true`
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });
    const dep_zdt = b.dependency("zdt", .{ .target = target, .optimize = optimize });
    const dep_libraw = b.dependency("libraw", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_wgpu_native = b.dependency("wgpu_native_zig", .{ .target = target, .optimize = optimize });
    const dep_zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_ztracy = b.dependency("ztracy", .{
        .enable_ztracy = ztracy_options.enable_ztracy,
        .enable_fibers = ztracy_options.enable_fibers,
        .on_demand = ztracy_options.on_demand,
    });
    const dep_zpool = b.dependency("zpool", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_sizeify = b.dependency("sizeify", .{
        .target = target,
        .optimize = optimize,
    });
    const termsize = b.dependency("termsize", .{
        .target = target,
        .optimize = optimize,
    });

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));

    // OPTIONS
    // see tigerbeetle for advanced build options handling
    // https://github.com/tigerbeetle/tigerbeetle/blob/main/build.zig
    const mod_options = b.addOptions();
    mod_options.addOption(
        i64,
        "timestamp",
        std.time.timestamp(),
    );
    mod_options.addOption(bool, "docking", opt_docking);

    // MAIN MODULE
    // main module with sokol and cimgui imports
    const mod_main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_main.addOptions("build_options", mod_options);
    mod_main.addImport("sokol", dep_sokol.module("sokol"));
    mod_main.addImport(cimgui_conf.module_name, dep_cimgui.module(cimgui_conf.module_name));
    mod_main.addImport("pretty", dep_pretty.module("pretty"));
    mod_main.addImport("zdt", dep_zdt.module("zdt"));
    mod_main.addImport("libraw", dep_libraw.module("libraw"));
    mod_main.addImport("wgpu", dep_wgpu_native.module("wgpu"));
    mod_main.addImport("wgpu-c", dep_wgpu_native.module("wgpu-c"));
    mod_main.addImport("zigimg", dep_zigimg.module("zigimg"));
    // mod_main.addImport("ztracy", dep_ztracy.module("root"));
    mod_main.addImport("zpool", dep_zpool.module("root"));
    mod_main.addImport("sizeify", dep_sizeify.module("sizeify"));
    mod_main.addImport("termsize", termsize.module("termsize"));

    // TESTS
    // UNIT TESTS
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .name = "unit tests",
        .root_module = mod_main,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // INTEGRATION TESTS
    const integration_test_step = b.step("integration", "Run integration tests");
    // first run the zig code as an executable
    const mod_integration_test = b.createModule(.{
        .root_source_file = b.path("testing/integration/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_integration_test.addImport("pie", mod_main);
    mod_integration_test.addImport("pretty", dep_pretty.module("pretty"));
    // mod_integration_test.addImport("termsize", termsize.module("termsize"));
    mod_integration_test.addImport("libraw", dep_libraw.module("libraw"));
    mod_integration_test.addImport("zigimg", dep_zigimg.module("zigimg"));
    mod_integration_test.addImport("ztracy", dep_ztracy.module("root"));
    mod_integration_test.addImport("zpool", dep_zpool.module("root"));
    const integration_tests_exe = b.addExecutable(.{
        .name = "integration tests exe",
        .root_module = mod_integration_test,
    });
    integration_tests_exe.linkLibrary(dep_ztracy.artifact("tracy"));
    const integration_test_runner = b.addRunArtifact(integration_tests_exe);
    test_step.dependOn(&integration_test_runner.step);
    const integration_tests_tests = b.addTest(.{
        .name = "integration tests tests",
        .root_module = mod_integration_test,
        .test_runner = .{ .path = b.path("testing/test_runner.zig"), .mode = .simple },
    });
    const run_integration_tests = b.addRunArtifact(integration_tests_tests);
    integration_test_step.dependOn(&run_integration_tests.step);

    // from here on different handling for native vs wasm builds
    if (target.result.cpu.arch.isWasm()) {
        try buildWasm(b, .{
            .mod_main = mod_main,
            .dep_sokol = dep_sokol,
            .dep_cimgui = dep_cimgui,
            .cimgui_clib_name = cimgui_conf.clib_name,
        });
    } else {
        try buildNative(b, mod_main);
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
        exe.addLibraryPath(system_library_path);
    }
    b.installArtifact(exe);
    b.step("run", "Run pie").dependOn(&b.addRunArtifact(exe).step);
}

const BuildWasmOptions = struct {
    mod_main: *Build.Module,
    dep_sokol: *Dependency,
    dep_cimgui: *Dependency,
    cimgui_clib_name: []const u8,
};

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
    opts.dep_cimgui.artifact(opts.cimgui_clib_name).addSystemIncludePath(emsdk_incl_path);

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
