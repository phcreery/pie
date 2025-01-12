const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Dependency = Build.Dependency;
const sokol = @import("sokol");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    // const target = b.resolveTargetQuery(.{
    //     .ofmt = .c,
    // });
    const optimize = b.standardOptimizeOption(.{});

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
    const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });

    // see tigerbeetle for advanced build options handling
    // https://github.com/tigerbeetle/tigerbeetle/blob/main/build.zig
    // https://ziggit.dev/t/equivalent-of-cs-date-and-time-macros/2076/2
    const build_options = b.addOptions();
    build_options.addOption(
        i64,
        "timestamp",
        std.time.timestamp(),
    );

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));

    // main module with sokol and cimgui imports
    const mod_main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
            .{ .name = "pretty", .module = pretty.module("pretty") },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    // mod_main.addImport("pretty", pretty.module("pretty"));

    // from here on different handling for native vs wasm builds
    if (target.result.isWasm()) {
        try buildWasm(b, mod_main, dep_sokol, dep_cimgui);
    } else {
        try buildNative(b, mod_main);
    }
}

fn buildNative(b: *Build, mod: *Build.Module) !void {
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = mod,
    });
    b.installArtifact(exe);
    b.step("run", "Run demo").dependOn(&b.addRunArtifact(exe).step);
}

fn buildWasm(b: *Build, mod: *Build.Module, dep_sokol: *Dependency, dep_cimgui: *Dependency) !void {
    // build the main file into a library, this is because the WASM 'exe'
    // needs to be linked in a separate build step with the Emscripten linker
    const demo = b.addStaticLibrary(.{
        .name = "demo",
        .root_module = mod,
    });

    // get the Emscripten SDK dependency from the sokol dependency
    const dep_emsdk = dep_sokol.builder.dependency("emsdk", .{});

    // need to inject the Emscripten system header include path into
    // the cimgui C library otherwise the C/C++ code won't find
    // C stdlib headers
    const emsdk_incl_path = dep_emsdk.path("upstream/emscripten/cache/sysroot/include");
    dep_cimgui.artifact("cimgui_clib").addSystemIncludePath(emsdk_incl_path);

    // all C libraries need to depend on the sokol library, when building for
    // WASM this makes sure that the Emscripten SDK has been setup before
    // C compilation is attempted (since the sokol C library depends on the
    // Emscripten SDK setup step)
    dep_cimgui.artifact("cimgui_clib").step.dependOn(&dep_sokol.artifact("sokol_clib").step);

    // create a build step which invokes the Emscripten linker
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = demo,
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
        .emsdk = dep_emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = dep_sokol.path("src/sokol/web/shell.html"),
    });
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "demo", .emsdk = dep_emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run demo").dependOn(&run.step);
}
