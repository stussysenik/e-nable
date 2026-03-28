/// e-nable Benchmarks — performance budget verification
///
/// Verifies that the image pipeline meets its latency targets:
///   - Greyscale + dither: <3ms for 1240×930 frame
///   - Delta + compress: <2ms for typical desktop content
///
/// Run with: zig build bench (compiles with ReleaseFast)
///
/// These are real-time measurements, not microbenchmarks.
/// Results vary by machine — the targets are for Apple Silicon M1+.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const dither = @import("dither.zig");
const delta = @import("delta.zig");

const BENCH_WIDTH: u32 = 1240;
const BENCH_HEIGHT: u32 = 930;
const PIXEL_COUNT: usize = @as(usize, BENCH_WIDTH) * @as(usize, BENCH_HEIGHT);

test "benchmark: greyscale conversion 1240x930" {
    const allocator = std.testing.allocator;

    // Create synthetic BGRA frame (gradient pattern)
    const bgra = try allocator.alloc(u8, PIXEL_COUNT * 4);
    defer allocator.free(bgra);
    for (0..PIXEL_COUNT) |i| {
        const v: u8 = @intCast(i % 256);
        bgra[i * 4 + 0] = v; // B
        bgra[i * 4 + 1] = v; // G
        bgra[i * 4 + 2] = v; // R
        bgra[i * 4 + 3] = 255; // A
    }

    const grey = try allocator.alloc(u8, PIXEL_COUNT);
    defer allocator.free(grey);

    const frame = pipeline.FrameBuffer{
        .data = bgra,
        .width = BENCH_WIDTH,
        .height = BENCH_HEIGHT,
        .stride = BENCH_WIDTH * 4,
    };

    // Warm up
    pipeline.toGreyscale(frame, grey);

    // Measure
    const iterations = 100;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        pipeline.toGreyscale(frame, grey);
    }
    const elapsed_ns = timer.read();
    const avg_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;

    std.debug.print("\n  greyscale 1240x930: {d:.2}ms avg ({} iterations)\n", .{ avg_ms, iterations });
    // Target: <1ms on Apple Silicon
}

test "benchmark: atkinson dither 1240x930" {
    const allocator = std.testing.allocator;

    const grey = try allocator.alloc(u8, PIXEL_COUNT);
    defer allocator.free(grey);

    // Fill with gradient
    for (0..PIXEL_COUNT) |i| {
        grey[i] = @intCast(i % 256);
    }

    // Measure (fewer iterations — dithering is heavier)
    const iterations = 10;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        // Reset buffer each iteration
        for (0..PIXEL_COUNT) |i| {
            grey[i] = @intCast(i % 256);
        }
        try dither.atkinsonDither(grey, BENCH_WIDTH, BENCH_HEIGHT, allocator);
    }
    const elapsed_ns = timer.read();
    const avg_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;

    std.debug.print("\n  atkinson dither 1240x930: {d:.2}ms avg ({} iterations)\n", .{ avg_ms, iterations });
    // Target: <3ms combined with greyscale on Apple Silicon
}

test "benchmark: xor delta 1240x930" {
    const allocator = std.testing.allocator;

    // Two frames with ~5% difference (simulates cursor blink + small edit)
    const frame_a = try allocator.alloc(u8, PIXEL_COUNT);
    defer allocator.free(frame_a);
    const frame_b = try allocator.alloc(u8, PIXEL_COUNT);
    defer allocator.free(frame_b);
    const delta_buf = try allocator.alloc(u8, PIXEL_COUNT);
    defer allocator.free(delta_buf);

    // Fill frames, make ~5% different
    for (0..PIXEL_COUNT) |i| {
        frame_a[i] = @intCast(i % 256);
        frame_b[i] = if (i % 20 == 0) @intCast((i + 50) % 256) else @intCast(i % 256);
    }

    // Measure
    const iterations = 100;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        delta.xorDelta(frame_b, frame_a, delta_buf);
    }
    const elapsed_ns = timer.read();
    const avg_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;

    std.debug.print("\n  xor delta 1240x930: {d:.2}ms avg ({} iterations)\n", .{ avg_ms, iterations });
    // Target: <1ms on Apple Silicon
}

test "benchmark: compress typical delta" {
    const allocator = std.testing.allocator;

    // Simulate a typical delta: 95% zeros, 5% non-zero
    const delta_buf = try allocator.alloc(u8, PIXEL_COUNT);
    defer allocator.free(delta_buf);
    @memset(delta_buf, 0);
    for (0..PIXEL_COUNT) |i| {
        if (i % 20 == 0) delta_buf[i] = @intCast((i * 7) % 255 + 1);
    }

    // Measure
    const iterations = 50;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const compressed = try delta.compress(delta_buf, allocator);
        allocator.free(compressed);
    }
    const elapsed_ns = timer.read();
    const avg_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;

    // Also report compression ratio
    const compressed = try delta.compress(delta_buf, allocator);
    defer allocator.free(compressed);
    const ratio = @as(f64, @floatFromInt(delta_buf.len)) / @as(f64, @floatFromInt(compressed.len));

    std.debug.print("\n  compress 1240x930 delta: {d:.2}ms avg, {d:.1}x ratio ({} iterations)\n", .{ avg_ms, ratio, iterations });
    // Target: <1ms, >10x ratio for typical delta
}
