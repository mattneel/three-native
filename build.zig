const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mquickjs_path = b.path("deps/mquickjs");

    // Step 1: Generate mquickjs stdlib headers (requires running host tools)
    const gen_stdlib = b.addSystemCommand(&.{
        "make", "-C", "deps/mquickjs", "example_stdlib.h", "mquickjs_atom.h",
    });

    // Step 2: Build mquickjs as static library using system compiler
    // We use gcc because mquickjs relies on specific alignment behavior
    const build_mquickjs = b.addSystemCommand(&.{
        "make", "-C", "deps/mquickjs", "example",
    });
    build_mquickjs.step.dependOn(&gen_stdlib.step);

    // Step 3: Create the static library archive
    const create_archive = b.addSystemCommand(&.{
        "ar", "rcs", "deps/mquickjs/libmquickjs.a",
        "deps/mquickjs/mquickjs.o",
        "deps/mquickjs/dtoa.o",
        "deps/mquickjs/libm.o",
        "deps/mquickjs/cutils.o",
    });
    create_archive.step.dependOn(&build_mquickjs.step);

    // Step 4: Compile our JS runtime wrapper
    const compile_runtime = b.addSystemCommand(&.{
        "gcc", "-Wall", "-g", "-D_GNU_SOURCE", "-fno-math-errno", "-fno-trapping-math", "-Os",
        "-I", "deps/mquickjs",
        "-c", "-o", "src/js_runtime.o",
        "src/js_runtime.c",
    });
    compile_runtime.step.dependOn(&build_mquickjs.step);

    // Step 5: Add runtime to archive
    const add_runtime = b.addSystemCommand(&.{
        "ar", "rcs", "deps/mquickjs/libmquickjs.a",
        "deps/mquickjs/mquickjs.o",
        "deps/mquickjs/dtoa.o",
        "deps/mquickjs/libm.o",
        "deps/mquickjs/cutils.o",
        "src/js_runtime.o",
    });
    add_runtime.step.dependOn(&create_archive.step);
    add_runtime.step.dependOn(&compile_runtime.step);

    // Create module for Zig code
    const mod = b.addModule("three_native", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "three_native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "three_native", .module = mod },
            },
        }),
    });

    // Link pre-built mquickjs static library
    exe.addObjectFile(b.path("deps/mquickjs/libmquickjs.a"));
    exe.addIncludePath(mquickjs_path);
    exe.linkLibC();
    exe.linkSystemLibrary("m");

    // Make exe depend on the library build
    exe.step.dependOn(&add_runtime.step);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Clean step
    const clean_step = b.step("clean", "Clean build artifacts");
    const clean_cmd = b.addSystemCommand(&.{
        "make", "-C", "deps/mquickjs", "clean",
    });
    const clean_runtime = b.addSystemCommand(&.{
        "rm", "-f", "src/js_runtime.o",
    });
    clean_step.dependOn(&clean_cmd.step);
    clean_step.dependOn(&clean_runtime.step);
}
