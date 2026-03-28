const std = @import("std");

/// e-nable Zig Core — shared image processing library
///
/// This build file compiles the Zig core library for both macOS and Android.
/// The library provides:
///   - Image pipeline: greyscale conversion, contrast LUT, sharpening, dithering
///   - Delta encoding: XOR differencing, dirty region detection, LZ4 compression
///   - C ABI exports: callable from Swift (macOS) and Kotlin via JNI (Android)
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core library ──────────────────────────────────────────────
    //
    // Compiles as a static library with C ABI exports.
    // Swift links this via bridging header; Android loads via JNI.
    const lib = b.addLibrary(.{
        .name = "enable-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // ── Unit tests ────────────────────────────────────────────────
    //
    // Run with: zig build test
    // Tests are embedded in source files using Zig's built-in test framework.
    // Each module (pipeline, delta, dither, color) has its own test block.
    const test_step = b.step("test", "Run all unit tests");

    // Pipeline tests (greyscale, LUT, sharpening)
    const pipeline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pipeline.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(pipeline_tests).step);

    // Dithering tests (Atkinson algorithm)
    const dither_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dither.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(dither_tests).step);

    // Delta encoding tests (XOR, dirty regions, roundtrip)
    const delta_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/delta.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(delta_tests).step);

    // Color quantization tests (octree)
    const color_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/color.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(color_tests).step);

    // FFI export tests
    const ffi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ffi_tests).step);

    // ── Benchmarks ────────────────────────────────────────────────
    //
    // Run with: zig build bench
    // Verifies performance budgets: pipeline <3ms, delta <2ms for 1240x930.
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
