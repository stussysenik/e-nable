/// e-nable FFI — C ABI exports for Swift and JNI consumers
///
/// This module exposes the Zig core library through a stable C ABI.
/// On macOS, Swift calls these via a bridging header.
/// On Android, Kotlin calls these via a thin JNI wrapper (zig_bridge.c).
///
/// Design principle: the FFI layer is a thin translation layer.
/// It converts C types to Zig types, calls the real implementation,
/// and converts results back. No business logic lives here.
///
/// Implementation: Phase v0.3.0+ (when Swift/Kotlin integration begins)
/// For now, provides type definitions and stub exports.

const std = @import("std");
const pipeline = @import("pipeline.zig");
const dither = @import("dither.zig");
const delta = @import("delta.zig");

// ── C-compatible type definitions ─────────────────────────────────
//
// These match the Zig internal types but use C-safe representations.
// Exported in the C header via `zig build` with `-femit-h`.

pub const EnableFrameBuffer = extern struct {
    pixels: [*]u8,
    width: u32,
    height: u32,
    stride: u32,
};

pub const EnableProcessedFrame = extern struct {
    pixels: [*]u8,
    width: u32,
    height: u32,
    mode: u8, // 0 = bw, 1 = color
};

pub const EnableConfig = extern struct {
    gamma: f32,
    sharpen_amount: f32,
    dither_mode: u8, // 0 = atkinson, 1 = none
    color_mode: u8, // 0 = bw, 1 = color
};

// ── Exported functions ────────────────────────────────────────────

/// Convert BGRA frame to greyscale. Caller provides output buffer.
export fn enable_to_greyscale(
    bgra: [*]const u8,
    grey: [*]u8,
    width: u32,
    height: u32,
) void {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const frame = pipeline.FrameBuffer{
        .data = bgra[0 .. pixel_count * 4],
        .width = width,
        .height = height,
        .stride = width * 4,
    };
    const output = grey[0..pixel_count];
    pipeline.toGreyscale(frame, output);
}

/// Apply Atkinson dithering in-place on greyscale buffer.
export fn enable_atkinson_dither(
    pixels: [*]u8,
    width: u32,
    height: u32,
) i32 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const buf = pixels[0..pixel_count];
    dither.atkinsonDither(buf, width, height, std.heap.page_allocator) catch return -1;
    return 0;
}

/// Compute XOR delta between two frames. Caller provides delta buffer.
export fn enable_xor_delta(
    current: [*]const u8,
    previous: [*]const u8,
    delta_out: [*]u8,
    len: u32,
) void {
    const size = @as(usize, len);
    delta.xorDelta(current[0..size], previous[0..size], delta_out[0..size]);
}

// ── Tests ─────────────────────────────────────────────────────────

test "ffi greyscale export callable" {
    // White pixel: BGRA = (255, 255, 255, 255)
    const bgra = [_]u8{ 255, 255, 255, 255 };
    var grey = [_]u8{0};
    enable_to_greyscale(&bgra, &grey, 1, 1);
    // Should be ~255 (white)
    try std.testing.expect(grey[0] >= 254);
}

test "ffi xor delta export callable" {
    const a = [_]u8{ 10, 20, 30, 40 };
    const b = [_]u8{ 10, 25, 30, 40 };
    var d = [_]u8{ 0, 0, 0, 0 };
    enable_xor_delta(&a, &b, &d, 4);
    try std.testing.expectEqual(@as(u8, 0), d[0]);
    try std.testing.expect(d[1] != 0); // 20 XOR 25
    try std.testing.expectEqual(@as(u8, 0), d[2]);
    try std.testing.expectEqual(@as(u8, 0), d[3]);
}
