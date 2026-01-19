const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mquickjs_path = b.path("deps/mquickjs");

    // ==========================================================================
    // Sokol dependency
    // ==========================================================================
    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // ==========================================================================
    // mquickjs header generation
    // ==========================================================================

    // Build example_stdlib generator (includes mquickjs_build.c)
    const example_stdlib_gen = b.addExecutable(.{
        .name = "example_stdlib_gen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    example_stdlib_gen.addCSourceFiles(.{
        .root = mquickjs_path,
        .files = &.{ "example_stdlib.c", "mquickjs_build.c" },
        .flags = &.{"-D_GNU_SOURCE"},
    });
    example_stdlib_gen.addIncludePath(mquickjs_path);
    example_stdlib_gen.linkLibC();

    // Run example_stdlib to generate example_stdlib.h
    const gen_example_stdlib = b.addRunArtifact(example_stdlib_gen);
    const example_stdlib_h = gen_example_stdlib.captureStdOut();

    // Build mqjs_stdlib generator (for atom table)
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
        .flags = &.{"-D_GNU_SOURCE"},
    });
    mqjs_stdlib_gen.addIncludePath(mquickjs_path);
    mqjs_stdlib_gen.linkLibC();

    // Run mqjs_stdlib -a to generate mquickjs_atom.h
    const gen_atom_h = b.addRunArtifact(mqjs_stdlib_gen);
    gen_atom_h.addArg("-a");
    const mquickjs_atom_h = gen_atom_h.captureStdOut();

    // Write generated headers to a generated directory
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(example_stdlib_h, "example_stdlib.h");
    _ = generated.addCopyFile(mquickjs_atom_h, "mquickjs_atom.h");
    const generated_include = generated.getDirectory();

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
    // Library module (for tests and reuse)
    // ==========================================================================
    const mod = b.addModule("three_native", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
            },
        }),
    });

    // Add mquickjs C sources
    exe.addCSourceFiles(.{
        .root = mquickjs_path,
        .files = &.{
            "mquickjs.c",
            "dtoa.c",
            "libm.c",
            "cutils.c",
        },
        .flags = c_flags,
    });

    // Add our JS runtime wrapper
    exe.addCSourceFiles(.{
        .files = &.{"src/js_runtime.c"},
        .flags = c_flags,
    });

    // Include paths: generated headers first, then mquickjs source
    exe.addIncludePath(generated_include);
    exe.addIncludePath(mquickjs_path);
    exe.addIncludePath(b.path("src"));
    exe.linkLibC();

    // Link sokol
    exe.root_module.linkLibrary(sokol_dep.artifact("sokol_clib"));

    b.installArtifact(exe);

    // ==========================================================================
    // Run step
    // ==========================================================================
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
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
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
