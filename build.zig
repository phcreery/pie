const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Dependency = Build.Dependency;
const sokol = @import("sokol");
const cimgui = @import("cimgui");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    // for testing only, forces a native build
    // const target = b.resolveTargetQuery(.{
    //     .ofmt = .c,
    // });
    const optimize = b.standardOptimizeOption(.{});

    const opt_docking = b.option(bool, "docking", "Build with docking support") orelse false;

    // Get the matching Zig module name, C header search path and C library for
    // vanilla imgui vs the imgui docking branch.
    const cimgui_conf = cimgui.getConfig(opt_docking);

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
    const dep_opencl = b.dependency("opencl", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_libraw = b.dependency("libraw", .{
        .target = target,
        .optimize = optimize,
    });

    // see tigerbeetle for advanced build options handling
    // https://github.com/tigerbeetle/tigerbeetle/blob/main/build.zig
    // https://ziggit.dev/t/equivalent-of-cs-date-and-time-macros/2076/2
    // const build_time_options = b.addOptions();
    const mod_options = b.addOptions();
    mod_options.addOption(
        i64,
        "timestamp",
        std.time.timestamp(),
    );
    mod_options.addOption(bool, "docking", opt_docking);

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));

    // main module with sokol and cimgui imports
    const mod_main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            .{ .name = "pretty", .module = dep_pretty.module("pretty") },
            .{ .name = "zdt", .module = dep_zdt.module("zdt") },
            .{ .name = "opencl", .module = dep_opencl.module("opencl") },
            .{ .name = "libraw", .module = dep_libraw.module("libraw") },
        },
    });
    mod_main.addOptions("build_options", mod_options);

    // build and run the unit tests
    const unit_tests = b.addTest(.{
        .name = "tests",
        .root_module = mod_main,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

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
