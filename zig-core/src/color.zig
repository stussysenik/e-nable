/// e-nable Color Quantization — octree algorithm for Kaleido 3 (4096 colors)
///
/// Quantizes full-color BGRA to 4096 representative colors matching
/// the Boox Note Air 3 C's Kaleido 3 panel. The panel uses an RGB
/// Color Filter Array (CFA) over a greyscale e-ink matrix, natively
/// supporting 4096 colors (4 bits per R/G/B channel).
///
/// Implementation: Phase v0.8.0 (color mode support)
/// For now, provides a pass-through stub so the build system compiles.

const std = @import("std");

/// Quantize a single BGRA pixel to 4-bit-per-channel (4096 colors).
///
/// Kaleido 3 uses 4 bits per channel = 16 levels per channel = 4096 total.
/// Each channel is quantized to the nearest of 16 evenly-spaced values:
/// 0, 17, 34, 51, ..., 238, 255.
pub fn quantizePixel(r: u8, g: u8, b: u8) struct { r: u8, g: u8, b: u8 } {
    return .{
        .r = quantizeChannel(r),
        .g = quantizeChannel(g),
        .b = quantizeChannel(b),
    };
}

/// Quantize a single channel to 4-bit (16 levels).
fn quantizeChannel(value: u8) u8 {
    // Same quantization as dithering: nearest of 0, 17, 34, ..., 255
    const v: u16 = @as(u16, value) + 8;
    const result = (v / 17) * 17;
    return @intCast(@min(result, 255));
}

/// Quantize entire BGRA buffer to 4096 colors (in-place).
///
/// For each pixel, snaps R, G, B to nearest 4-bit value.
/// Alpha channel is preserved unchanged.
pub fn quantizeBuffer(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        // BGRA byte order
        pixels[i] = quantizeChannel(pixels[i]); // B
        pixels[i + 1] = quantizeChannel(pixels[i + 1]); // G
        pixels[i + 2] = quantizeChannel(pixels[i + 2]); // R
        // pixels[i + 3] = A (unchanged)
    }
}

// ── Tests ─────────────────────────────────────────────────────────

test "quantize channel boundary values" {
    try std.testing.expectEqual(@as(u8, 0), quantizeChannel(0));
    try std.testing.expectEqual(@as(u8, 0), quantizeChannel(8));
    try std.testing.expectEqual(@as(u8, 17), quantizeChannel(9));
    try std.testing.expectEqual(@as(u8, 17), quantizeChannel(17));
    try std.testing.expectEqual(@as(u8, 255), quantizeChannel(255));
    try std.testing.expectEqual(@as(u8, 255), quantizeChannel(247));
}

test "quantize pixel maps to 4096 palette" {
    const result = quantizePixel(130, 200, 50);
    // Each channel should be a multiple of 17
    try std.testing.expect(result.r % 17 == 0);
    try std.testing.expect(result.g % 17 == 0);
    try std.testing.expect(result.b % 17 == 0);
}

test "quantize buffer in-place" {
    var pixels = [_]u8{ 50, 130, 200, 255 }; // BGRA
    quantizeBuffer(&pixels);
    try std.testing.expect(pixels[0] % 17 == 0); // B
    try std.testing.expect(pixels[1] % 17 == 0); // G
    try std.testing.expect(pixels[2] % 17 == 0); // R
    try std.testing.expectEqual(@as(u8, 255), pixels[3]); // A unchanged
}
