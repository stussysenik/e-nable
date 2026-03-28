/// Dither Module — Atkinson error-diffusion for e-ink 16-level greyscale
///
/// # Why Atkinson dithering?
///
/// E-ink displays (like the Boox Mira) typically support 16 grey levels (0..255
/// quantized to 0, 17, 34, ... 255). Naive quantization produces harsh banding
/// on smooth gradients. Atkinson dithering — the algorithm used in the original
/// Apple Macintosh — diffuses quantization error to neighboring pixels, creating
/// the illusion of more tonal levels through spatial patterns.
///
/// Atkinson is preferred over Floyd-Steinberg for e-ink because:
///   - It only diffuses 3/4 of the error (discards 1/4), producing crisper output
///   - Fewer neighbors (6 vs 8) = sharper text edges
///   - The slight error loss prevents the "muddy" look common with full-error diffusion
///
/// # Pipeline position
///
///   capture -> greyscale -> contrast LUT -> sharpen -> **dither** -> delta -> send
///
/// # Quantization math (integer only, no floats)
///
///   For 16 levels evenly spaced [0, 17, 34, ... 238, 255]:
///     quantized = clamp((value + 8) / 17 * 17, 0, 255)
///
///   The `+ 8` provides rounding to the nearest level (half of 17 ≈ 8.5).
///   All arithmetic uses u16 intermediates to avoid overflow.
///
/// # Atkinson error distribution pattern
///
///   Given pixel at position (x, y), error is distributed:
///
///         [ * ] [1/8] [1/8]
///   [1/8] [1/8] [1/8]
///         [1/8]
///
///   Total distributed: 6/8 = 3/4. The remaining 1/4 is intentionally discarded.
///
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

/// Selects which dithering algorithm to apply in the pipeline.
///
/// `.atkinson` is the default for e-ink — it provides the best text clarity
/// with natural-looking gradients. `.none` passes through with simple
/// quantization only (useful for screenshots or debugging).
pub const DitherMode = enum {
    /// Atkinson error-diffusion dithering (recommended for e-ink)
    atkinson,
    /// No dithering — quantize only (useful for debugging / screenshots)
    none,
};

// ============================================================================
// Quantization
// ============================================================================

/// Quantize an 8-bit greyscale value to the nearest of 16 evenly-spaced levels.
///
/// The 16 levels are: 0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187,
/// 204, 221, 238, 255.
///
/// Uses integer-only arithmetic:
///   1. Promote to u16 to avoid overflow
///   2. Add 8 (half-step rounding)
///   3. Divide by 17, multiply by 17 to snap to nearest level
///   4. Clamp to 255 (since 248 + 8 = 256, / 17 = 15, * 17 = 255 — safe,
///      but we clamp defensively)
///
/// # Example
///   quantizeToSixteen(0)   = 0    (black)
///   quantizeToSixteen(9)   = 17   (rounds up from mid-bucket)
///   quantizeToSixteen(128) = 136  (mid-grey snaps to nearest level)
///   quantizeToSixteen(255) = 255  (white stays white)
pub fn quantizeToSixteen(value: u8) u8 {
    const wide: u16 = @as(u16, value);
    const quantized: u16 = (wide + 8) / 17 * 17;
    return @intCast(@min(quantized, 255));
}

// ============================================================================
// Atkinson Dithering
// ============================================================================

/// Apply Atkinson error-diffusion dithering in-place on a greyscale pixel buffer.
///
/// # Algorithm
///
/// For each pixel (left-to-right, top-to-bottom):
///   1. Read the accumulated pixel value (original + error from earlier pixels)
///   2. Clamp to [0, 255] and quantize to nearest of 16 levels
///   3. Compute error = old_value - quantized_value
///   4. Distribute error/8 to 6 neighbors (if in bounds):
///      - (x+1, y), (x+2, y)          — right neighbors
///      - (x-1, y+1), (x, y+1), (x+1, y+1)  — next row
///      - (x, y+2)                     — two rows down
///
/// # Memory
///
/// Uses an i16 error accumulation buffer (allocated via `alloc`) to prevent
/// quantization drift. The buffer stores intermediate values that may exceed
/// 0-255 during error diffusion.
///
/// # Parameters
///   - `pixels`: greyscale pixel buffer (modified in-place), length = width * height
///   - `width`: image width in pixels
///   - `height`: image height in pixels
///   - `alloc`: allocator for the temporary i16 error buffer
///
/// # Errors
///   - Returns `error.OutOfMemory` if the error buffer cannot be allocated
pub fn atkinsonDither(pixels: []u8, width: u32, height: u32, alloc: Allocator) !void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total: usize = w * h;
    if (total == 0) return;
    if (pixels.len < total) return;

    // ── Compile-time quantization LUT ───────────────────────────────
    //
    // Eliminates the integer division by 17 in the hot loop. A single
    // table lookup replaces: clamp → promote → add 8 → divide → multiply → clamp.
    const quant_lut = comptime blk: {
        var lut: [256]u8 = undefined;
        for (0..256) |i| {
            const q: u16 = (@as(u16, i) + 8) / 17 * 17;
            lut[i] = @intCast(@min(q, 255));
        }
        break :blk lut;
    };

    // ── Full-frame i16 error buffer ─────────────────────────────────
    //
    // We use a full-frame buffer for simplicity and to let the compiler
    // generate optimal code for the interior loop. At 1240x930 * 2 bytes
    // = 2.3 MB, this fits in L2 cache on Apple Silicon.
    const buf = try alloc.alloc(i16, total);
    defer alloc.free(buf);

    // Copy input pixels into the i16 buffer (single pass)
    for (buf, pixels[0..total]) |*b, px| {
        b.* = @as(i16, px);
    }

    // ── Pre-compute row stride offsets for Atkinson neighbors ───────
    //
    // Atkinson pattern relative to pixel at flat index `idx`:
    //         [*]  [+1]  [+2]
    //   [+w-1] [+w] [+w+1]
    //          [+2w]
    //
    // For the interior loop (where all neighbors are in-bounds), we use
    // these as direct offsets into the flat buffer.
    const w_i: isize = @intCast(w);

    // ── Process interior rows (y = 0 .. h-3) ────────────────────────
    //
    // For rows where y+2 < h, we can safely access row y+1 and y+2.
    // Within each such row, we split into:
    //   - left border (x=0): skip (x-1,y+1) neighbor
    //   - interior (x=1 .. w-3): all 6 neighbors guaranteed in-bounds
    //   - right border (x=w-2 .. w-1): some right neighbors out of bounds
    const interior_rows = if (h > 2) h - 2 else 0;

    for (0..interior_rows) |y| {
        const row_base = y * w;
        const buf_row = buf[row_base..];

        // Left border: x = 0
        {
            const val = std.math.clamp(buf_row[0], 0, 255);
            const clamped: u8 = @intCast(val);
            const quantized = quant_lut[clamped];
            pixels[row_base] = quantized;
            const diffused: i16 = @divTrunc(@as(i16, clamped) - @as(i16, quantized), 8);

            if (diffused != 0) {
                buf_row[1] += diffused; // (1, y)
                if (w > 2) buf_row[2] += diffused; // (2, y)
                // skip (-1, y+1) — out of bounds
                buf[row_base + w] += diffused; // (0, y+1)
                buf[row_base + w + 1] += diffused; // (1, y+1)
                buf[row_base + 2 * w] += diffused; // (0, y+2)
            }
        }

        // Interior: x = 1 .. w-3 (all 6 neighbors in-bounds, no branches)
        if (w > 3) {
            const interior_end = w - 2;
            var x: usize = 1;
            while (x < interior_end) : (x += 1) {
                const idx = row_base + x;
                const val = std.math.clamp(buf[idx], 0, 255);
                const clamped: u8 = @intCast(val);
                const quantized = quant_lut[clamped];
                pixels[idx] = quantized;
                const diffused: i16 = @divTrunc(@as(i16, clamped) - @as(i16, quantized), 8);

                // Branchless: if diffused is 0 (exact level), skip all 6 stores.
                // This is common for already-quantized content.
                if (diffused != 0) {
                    const p: [*]i16 = buf.ptr + idx;
                    p[1] += diffused; // (x+1, y)
                    p[2] += diffused; // (x+2, y)
                    (p + @as(usize, @intCast(w_i - 1)))[0] += diffused; // (x-1, y+1)
                    (p + @as(usize, @intCast(w_i)))[0] += diffused; // (x, y+1)
                    (p + @as(usize, @intCast(w_i + 1)))[0] += diffused; // (x+1, y+1)
                    (p + @as(usize, @intCast(2 * w_i)))[0] += diffused; // (x, y+2)
                }
            }
        }

        // Right border: x = max(1, w-2) .. w-1
        {
            const right_start: usize = if (w > 3) w - 2 else @min(w, 1);
            for (right_start..w) |x| {
                const idx = row_base + x;
                const val = std.math.clamp(buf[idx], 0, 255);
                const clamped: u8 = @intCast(val);
                const quantized = quant_lut[clamped];
                pixels[idx] = quantized;
                const diffused: i16 = @divTrunc(@as(i16, clamped) - @as(i16, quantized), 8);

                if (diffused != 0) {
                    if (x + 1 < w) buf[idx + 1] += diffused;
                    if (x + 2 < w) buf[idx + 2] += diffused;
                    buf[idx + w - 1] += diffused; // (x-1, y+1) — x >= 1 here
                    buf[idx + w] += diffused; // (x, y+1)
                    if (x + 1 < w) buf[idx + w + 1] += diffused;
                    buf[idx + 2 * w] += diffused; // (x, y+2)
                }
            }
        }
    }

    // ── Process bottom border rows (y = h-2, h-1) ──────────────────
    //
    // These rows need bounds checking for y+1 and y+2 neighbors.
    const bottom_start = interior_rows;
    for (bottom_start..h) |y| {
        const row_base = y * w;
        const has_row1 = y + 1 < h;
        const has_row2 = y + 2 < h;

        for (0..w) |x| {
            const idx = row_base + x;
            const val = std.math.clamp(buf[idx], 0, 255);
            const clamped: u8 = @intCast(val);
            const quantized = quant_lut[clamped];
            pixels[idx] = quantized;
            const diffused: i16 = @divTrunc(@as(i16, clamped) - @as(i16, quantized), 8);

            if (diffused != 0) {
                if (x + 1 < w) buf[idx + 1] += diffused;
                if (x + 2 < w) buf[idx + 2] += diffused;
                if (has_row1) {
                    if (x > 0) buf[idx + w - 1] += diffused;
                    buf[idx + w] += diffused;
                    if (x + 1 < w) buf[idx + w + 1] += diffused;
                }
                if (has_row2) buf[idx + 2 * w] += diffused;
            }
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Process a greyscale frame through the dithering stage of the pipeline.
///
/// Copies `input` into `output`, then applies Atkinson dithering in-place.
/// This non-destructive API preserves the original frame for delta encoding
/// (which needs the previous undithered frame for comparison).
///
/// # Parameters
///   - `input`: source greyscale pixels (read-only), length >= width * height
///   - `output`: destination buffer (will be overwritten), length >= width * height
///   - `width`: image width in pixels
///   - `height`: image height in pixels
///   - `mode`: which dithering algorithm to apply
///   - `alloc`: allocator for temporary buffers
///
/// # Errors
///   - Returns `error.OutOfMemory` if internal buffers cannot be allocated
pub fn ditherFrame(
    input: []const u8,
    output: []u8,
    width: u32,
    height: u32,
    mode: DitherMode,
    alloc: Allocator,
) !void {
    const total: usize = @as(usize, width) * @as(usize, height);

    // Copy input to output (output will be modified in-place by dithering)
    @memcpy(output[0..total], input[0..total]);

    switch (mode) {
        .atkinson => try atkinsonDither(output, width, height, alloc),
        .none => {
            // Quantize-only mode: snap each pixel to nearest of 16 levels
            for (output[0..total]) |*px| {
                px.* = quantizeToSixteen(px.*);
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

// ── Test 1: quantizeToSixteen boundary values ─────────────────────────────
//
// Verifies that the quantization function correctly snaps to the 16 grey
// levels at key boundary points: black, white, bucket midpoints, and edges.

test "quantizeToSixteen snaps to nearest 16-level grey" {
    // Exact level boundaries should be preserved
    try testing.expectEqual(@as(u8, 0), quantizeToSixteen(0));
    try testing.expectEqual(@as(u8, 17), quantizeToSixteen(17));
    try testing.expectEqual(@as(u8, 255), quantizeToSixteen(255));

    // Values below midpoint round down, at/above midpoint round up
    // Bucket [0..16]: midpoint is ~8.5 → 8 rounds down to 0, 9 rounds up to 17
    try testing.expectEqual(@as(u8, 0), quantizeToSixteen(8));
    try testing.expectEqual(@as(u8, 17), quantizeToSixteen(9));

    // Mid-grey: 128 is in bucket [119..135], midpoint ~127.5
    // 128 + 8 = 136, / 17 = 8, * 17 = 136
    try testing.expectEqual(@as(u8, 136), quantizeToSixteen(128));

    // High values near 255
    try testing.expectEqual(@as(u8, 238), quantizeToSixteen(238));
    try testing.expectEqual(@as(u8, 255), quantizeToSixteen(247));
    try testing.expectEqual(@as(u8, 255), quantizeToSixteen(250));
}

// ── Test 2: quantizeToSixteen covers all 256 input values ─────────────────
//
// Ensures every possible u8 input produces a valid 16-level output.
// "Valid" means the output is one of: 0, 17, 34, ... 238, 255.

test "quantizeToSixteen produces valid levels for all u8 inputs" {
    var i: u16 = 0;
    while (i <= 255) : (i += 1) {
        const input: u8 = @intCast(i);
        const result = quantizeToSixteen(input);
        // Result must be divisible by 17, OR equal to 255
        // (255 = 15 * 17, so it's already divisible by 17)
        try testing.expect(result % 17 == 0);
    }
}

// ── Test 3: Atkinson dither modifies a gradient in-place ──────────────────
//
// A smooth horizontal gradient should be visibly altered by dithering.
// We verify that at least some pixels changed from their quantized-only value,
// indicating error diffusion is happening.

test "atkinsonDither modifies gradient pixels via error diffusion" {
    const width: u32 = 16;
    const height: u32 = 4;
    var pixels: [width * height]u8 = undefined;

    // Fill with a smooth horizontal gradient 0..63 across 16 columns, repeated per row
    for (0..height) |y| {
        for (0..width) |x| {
            pixels[y * width + x] = @intCast(x * 4);
        }
    }

    // Keep a copy to compare against quantize-only
    var quantized_only: [width * height]u8 = pixels;
    for (&quantized_only) |*px| {
        px.* = quantizeToSixteen(px.*);
    }

    try atkinsonDither(&pixels, width, height, testing.allocator);

    // After dithering, every pixel must be a valid 16-level value
    for (pixels) |px| {
        try testing.expect(px % 17 == 0);
    }

    // At least some pixels should differ from naive quantization
    // (error diffusion pushes neighbors to different levels)
    var diff_count: usize = 0;
    for (pixels, 0..) |px, i| {
        if (px != quantized_only[i]) diff_count += 1;
    }
    try testing.expect(diff_count > 0);
}

// ── Test 4: Atkinson preserves pure black and pure white ──────────────────
//
// A uniform black or white image has zero quantization error, so dithering
// should produce output identical to the input.

test "atkinsonDither preserves uniform black and white" {
    const width: u32 = 8;
    const height: u32 = 8;

    // All black
    var black: [width * height]u8 = [_]u8{0} ** (width * height);
    try atkinsonDither(&black, width, height, testing.allocator);
    for (black) |px| {
        try testing.expectEqual(@as(u8, 0), px);
    }

    // All white
    var white: [width * height]u8 = [_]u8{255} ** (width * height);
    try atkinsonDither(&white, width, height, testing.allocator);
    for (white) |px| {
        try testing.expectEqual(@as(u8, 255), px);
    }
}

// ── Test 5: ditherFrame copies without mutating input ─────────────────────
//
// The public API must not modify the input buffer. This test verifies
// that `input` remains unchanged after `ditherFrame` completes.

test "ditherFrame does not mutate input buffer" {
    const width: u32 = 8;
    const height: u32 = 4;
    var input: [width * height]u8 = undefined;
    var output: [width * height]u8 = undefined;

    // Fill input with a known gradient
    for (&input, 0..) |*px, i| {
        px.* = @intCast(i * 8);
    }

    // Save a copy of the original input
    const original = input;

    try ditherFrame(&input, &output, width, height, .atkinson, testing.allocator);

    // Input must be completely unchanged
    try testing.expectEqualSlices(u8, &original, &input);

    // Output must contain valid 16-level values
    for (output) |px| {
        try testing.expect(px % 17 == 0);
    }
}

// ── Test 6: DitherMode.none quantizes without error diffusion ─────────────
//
// In `.none` mode, each pixel is independently quantized. The result should
// exactly match calling `quantizeToSixteen` on each pixel individually.

test "ditherFrame with mode .none produces quantize-only output" {
    const width: u32 = 4;
    const height: u32 = 4;
    var input: [width * height]u8 = undefined;
    var output: [width * height]u8 = undefined;

    for (&input, 0..) |*px, i| {
        px.* = @intCast(i * 16);
    }

    try ditherFrame(&input, &output, width, height, .none, testing.allocator);

    // Every output pixel should match independent quantization
    for (output, 0..) |px, i| {
        try testing.expectEqual(quantizeToSixteen(input[i]), px);
    }
}

// ── Test 7: Atkinson energy conservation (total brightness) ───────────────
//
// Atkinson intentionally discards 1/4 of the quantization error.
// For a mid-grey image, the total output brightness should be close to
// (but not necessarily equal to) the input brightness. We verify the
// average stays within a reasonable tolerance band.

test "atkinsonDither total brightness stays within tolerance" {
    const width: u32 = 32;
    const height: u32 = 32;
    var pixels: [width * height]u8 = undefined;

    // Fill with uniform mid-grey (128)
    @memset(&pixels, 128);

    // Calculate input sum
    var input_sum: u64 = 0;
    for (pixels) |px| input_sum += @as(u64, px);

    try atkinsonDither(&pixels, width, height, testing.allocator);

    // Calculate output sum
    var output_sum: u64 = 0;
    for (pixels) |px| output_sum += @as(u64, px);

    // Average should be within ±15 of original (128).
    // Atkinson's 1/4 error loss shifts brightness slightly, but not drastically.
    const count: u64 = width * height;
    const input_avg = input_sum / count;
    const output_avg = output_sum / count;

    const diff: i64 = @as(i64, @intCast(output_avg)) - @as(i64, @intCast(input_avg));
    const abs_diff: u64 = @intCast(if (diff < 0) -diff else diff);
    try testing.expect(abs_diff <= 15);
}
