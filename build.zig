const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mquickjs_path = b.path("deps/mquickjs");

    // C flags for mquickjs compilation
    // Note: mquickjs uses pointer arithmetic patterns that trigger Zig's UB sanitizer
    // but are valid in practice. We disable the sanitizers for mquickjs code.
    const c_flags = &[_][]const u8{
        "-D_GNU_SOURCE",
        "-fno-math-errno",
        "-fno-trapping-math",
        "-fno-strict-aliasing",
        "-fwrapv",
        "-fno-sanitize=undefined",
        "-fno-sanitize=null",
    };

    // ==========================================================================
    // Sokol dependency
    // ==========================================================================
    // Force OpenGL backend on all platforms for consistent GLSL shader support
    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gl = true,
    });

    // ==========================================================================
    // mquickjs header generation
    // ==========================================================================

    // Build mqjs_stdlib generator (includes mquickjs_build.c)
    const mqjs_stdlib_gen = b.addExecutable(.{
        .name = "mqjs_stdlib_gen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    mqjs_stdlib_gen.addCSourceFiles(.{
        .root = mquickjs_path,
        .files = &.{ "mqjs_stdlib.c", "mquickjs_build.c" },
        .flags = c_flags,
    });
    mqjs_stdlib_gen.addIncludePath(mquickjs_path);
    mqjs_stdlib_gen.linkLibC();

    // Run mqjs_stdlib to generate mqjs_stdlib.h
    const gen_mqjs_stdlib = b.addRunArtifact(mqjs_stdlib_gen);
    const mqjs_stdlib_h = gen_mqjs_stdlib.captureStdOut();

    // Run mqjs_stdlib -a to generate mquickjs_atom.h
    const gen_atom_h = b.addRunArtifact(mqjs_stdlib_gen);
    gen_atom_h.addArg("-a");
    const mquickjs_atom_h = gen_atom_h.captureStdOut();

    // Write generated headers to a generated directory
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(mqjs_stdlib_h, "mqjs_stdlib.h");
    _ = generated.addCopyFile(mquickjs_atom_h, "mquickjs_atom.h");
    const generated_include = generated.getDirectory();

    // ==========================================================================
    // mquickjs library (C sources compiled once)
    // ==========================================================================
    const mquickjs_lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mquickjs_lib = b.addLibrary(.{
        .name = "mquickjs",
        .linkage = .static,
        .root_module = mquickjs_lib_mod,
    });
    mquickjs_lib.addCSourceFiles(.{
        .root = mquickjs_path,
        .files = &.{
            "mquickjs.c",
            "dtoa.c",
            "libm.c",
            "cutils.c",
        },
        .flags = c_flags,
    });
    mquickjs_lib.addCSourceFiles(.{
        .files = &.{"src/runtime/mqjs_stdlib.c"},
        .flags = c_flags,
    });
    mquickjs_lib.addIncludePath(generated_include);
    mquickjs_lib.addIncludePath(mquickjs_path);
    mquickjs_lib.addIncludePath(b.path("src/runtime"));
    mquickjs_lib.linkLibC();

    // ==========================================================================
    // Zignal dependency (image processing)
    // ==========================================================================
    const zignal_dep = b.dependency("zignal", .{
        .target = target,
        .optimize = optimize,
    });

    // ==========================================================================
    // Library module (for tests and reuse)
    // ==========================================================================
    const mod = b.addModule("three_native", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = sokol_dep.module("sokol") },
            .{ .name = "zignal", .module = zignal_dep.module("zignal") },
        },
    });
    mod.linkLibrary(sokol_dep.artifact("sokol_clib"));

    // Add mquickjs include paths to module for @cImport
    mod.addIncludePath(generated_include);
    mod.addIncludePath(mquickjs_path);
    mod.addIncludePath(b.path("src/runtime"));

    // ==========================================================================
    // Main executable
    // ==========================================================================
    const exe = b.addExecutable(.{
        .name = "three_native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "three_native", .module = mod },
                .{ .name = "sokol", .module = sokol_dep.module("sokol") },
                .{ .name = "zignal", .module = zignal_dep.module("zignal") },
            },
        }),
    });

    exe.linkLibrary(mquickjs_lib);

    // Link sokol
    exe.root_module.linkLibrary(sokol_dep.artifact("sokol_clib"));

    b.installArtifact(exe);

    // ==========================================================================
    // Three.js ES5 bundle (esbuild + Babel)
    // ==========================================================================
    const npm_install = b.addSystemCommand(&.{ "npm", "install" });
    const npm_build_es5 = b.addSystemCommand(&.{ "npm", "run", "build:three-es5" });
    npm_build_es5.step.dependOn(&npm_install.step);

    const es5_step = b.step("three-es5", "Build the Three.js ES5 bundle");
    es5_step.dependOn(&npm_build_es5.step);

    // ==========================================================================
    // Run step
    // ==========================================================================
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(es5_step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ==========================================================================
    // Tests
    // ==========================================================================
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.linkLibrary(mquickjs_lib);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
