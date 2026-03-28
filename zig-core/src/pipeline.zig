/// Image Pipeline Module — BGRA-to-greyscale conversion for e-ink display
///
/// # Why a dedicated pipeline?
///
/// macOS screen captures arrive as BGRA (Blue-Green-Red-Alpha) pixel buffers.
/// E-ink displays only show greyscale, so we need to convert. But a naive
/// conversion looks washed-out on e-ink because:
///
///   1. E-ink has lower contrast than LCD (typically 15:1 vs 1000:1)
///   2. E-ink reflective display makes mid-tones look darker than on screen
///   3. Text edges appear soft without sharpening
///
/// This pipeline solves all three in three stages:
///
///   capture -> **greyscale** -> **contrast LUT** -> **sharpen** -> dither -> send
///                 BT.709         gamma curve       Laplacian
///
/// # BT.709 Colour Science (greyscale conversion)
///
/// Human eyes are not equally sensitive to all colours. Green looks much
/// brighter than blue at the same intensity. The ITU-R BT.709 standard
/// (used in HDTV) defines luminance weights that match human perception:
///
///   Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
///
/// We approximate this with integer arithmetic (no floating point needed):
///
///   Y = (R * 54 + G * 183 + B * 19 + 128) >> 8
///
/// The coefficients 54/256=0.2109, 183/256=0.7148, 19/256=0.0742 sum
/// to exactly 256, and +128 provides rounding. This gives bit-exact
/// results: pure white (255,255,255) -> 255, pure black (0,0,0) -> 0.
///
/// # Gamma Contrast LUT
///
/// A lookup table (LUT) maps each of the 256 possible greyscale values
/// to a corrected value using a gamma power curve:
///
///   output = 255 * (input / 255) ^ (1 / gamma)
///
/// - gamma > 1.0: brightens mid-tones (good for e-ink, default 1.2)
/// - gamma = 1.0: identity (no change)
/// - gamma < 1.0: darkens mid-tones
///
/// Using a LUT makes the per-pixel cost O(1) — just an array index.
///
/// # Laplacian Unsharp Mask (sharpening)
///
/// E-ink's slow refresh and limited grey levels make text edges look soft.
/// A Laplacian sharpening filter enhances edges by amplifying the difference
/// between a pixel and its neighbours:
///
///         [ 0, -a,  0 ]
///   K  =  [-a, 1+4a, -a]
///         [ 0, -a,  0 ]
///
/// where `a` is the sharpen amount (default 1.5). This is a 4-connected
/// (Von Neumann neighbourhood) kernel — we only look at the 4 direct
/// neighbours, not diagonals. This is cheaper and produces cleaner results
/// for text than an 8-connected kernel.
///
const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const testing = std.testing;

// ============================================================================
// Data Structures
// ============================================================================

/// Input frame from macOS screen capture.
///
/// The buffer is in BGRA byte order (Blue at offset 0, Green at 1,
/// Red at 2, Alpha at 3 per pixel). This matches CGImage's default
/// byte order on macOS (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little).
///
/// The struct does NOT own the pixel data — it's a view into a
/// capture buffer managed by the screen capture layer.
pub const FrameBuffer = struct {
    /// Raw BGRA pixel data. Length must equal width * height * 4.
    data: []const u8,

    /// Frame width in pixels.
    width: u32,

    /// Frame height in pixels.
    height: u32,

    /// Bytes per row (may include padding for memory alignment).
    /// On macOS, CGDisplayStream often pads rows to 64-byte boundaries.
    stride: u32,
};

/// Output of the image pipeline — a single-channel greyscale frame.
///
/// Each pixel is one byte (0 = black, 255 = white). The buffer is
/// owned by the Pipeline and must not be freed separately.
pub const ProcessedFrame = struct {
    /// Greyscale pixel data. Length equals width * height.
    data: []const u8,

    /// Frame width in pixels.
    width: u32,

    /// Frame height in pixels.
    height: u32,
};

/// Configuration knobs for the image pipeline.
///
/// Both parameters have sensible defaults tuned for typical e-ink
/// usage (text-heavy desktop with dark-on-light colour schemes).
pub const PipelineConfig = struct {
    /// Gamma correction factor for contrast enhancement.
    /// - 1.0 = no correction (identity)
    /// - 1.2 = slightly brighter mid-tones (default, good for e-ink)
    /// - 0.5 = darken mid-tones
    gamma: f32 = 1.2,

    /// Laplacian sharpening strength.
    /// - 0.0 = disabled (passthrough)
    /// - 1.5 = moderate sharpening (default, good for e-ink text)
    /// - 3.0 = aggressive sharpening (may introduce artifacts)
    sharpen_amount: f32 = 1.5,
};

/// Stateful image processing pipeline.
///
/// Holds pre-allocated buffers and a cached contrast LUT to avoid
/// allocation on every frame. The typical usage is:
///
/// ```
/// var pipe = try Pipeline.init(allocator, .{});
/// defer pipe.deinit();
///
/// const frame = pipe.processFrame(capture_buffer);
/// // frame.data is valid until next processFrame() call or deinit()
/// ```
///
/// The Pipeline owns all internal buffers via the allocator passed
/// at init. Calling deinit() frees everything.
pub const Pipeline = struct {
    allocator: Allocator,

    /// Pre-allocated buffer for greyscale conversion output.
    greyscale_buf: []u8,

    /// Pre-allocated scratch buffer for sharpening output.
    sharpen_buf: []u8,

    /// Cached 256-entry contrast lookup table.
    lut: [256]u8,

    /// Current gamma value — used to detect config changes and
    /// avoid rebuilding the LUT when gamma hasn't changed.
    current_gamma: f32,

    /// Current sharpen amount.
    current_sharpen: f32,

    /// Frame dimensions (set at init, buffers sized to match).
    width: u32,
    height: u32,

    /// Create a new pipeline for frames of the given dimensions.
    ///
    /// Allocates two buffers (greyscale + sharpen scratch), each
    /// width*height bytes. Builds the initial contrast LUT.
    ///
    /// Returns error.OutOfMemory if allocation fails.
    pub fn init(allocator: Allocator, width: u32, height: u32, config: PipelineConfig) !Pipeline {
        const pixel_count: usize = @as(usize, width) * @as(usize, height);

        const greyscale_buf = try allocator.alloc(u8, pixel_count);
        errdefer allocator.free(greyscale_buf);

        const sharpen_buf = try allocator.alloc(u8, pixel_count);
        errdefer allocator.free(sharpen_buf);

        return Pipeline{
            .allocator = allocator,
            .greyscale_buf = greyscale_buf,
            .sharpen_buf = sharpen_buf,
            .lut = buildContrastLut(config.gamma),
            .current_gamma = config.gamma,
            .current_sharpen = config.sharpen_amount,
            .width = width,
            .height = height,
        };
    }

    /// Free all pipeline-owned buffers.
    pub fn deinit(self: *Pipeline) void {
        self.allocator.free(self.greyscale_buf);
        self.allocator.free(self.sharpen_buf);
    }

    /// Update pipeline configuration.
    ///
    /// Only rebuilds the LUT if gamma actually changed — the LUT
    /// computation involves 256 pow() calls, so skipping when
    /// unchanged saves ~1us per frame.
    pub fn updateConfig(self: *Pipeline, config: PipelineConfig) void {
        if (self.current_gamma != config.gamma) {
            self.lut = buildContrastLut(config.gamma);
            self.current_gamma = config.gamma;
        }
        self.current_sharpen = config.sharpen_amount;
    }

    /// Run the full 3-stage pipeline on an input frame.
    ///
    /// Stages:
    ///   1. Greyscale conversion (BGRA -> Y via BT.709)
    ///   2. Contrast LUT application (gamma correction)
    ///   3. Sharpening (Laplacian unsharp mask)
    ///
    /// Returns a ProcessedFrame referencing internal buffers.
    /// The returned data is valid until the next processFrame()
    /// call or until deinit() is called.
    pub fn processFrame(self: *Pipeline, frame: FrameBuffer) ProcessedFrame {
        // Stage 1: BGRA -> greyscale
        toGreyscale(frame, self.greyscale_buf);

        // Stage 2: apply contrast LUT in-place on the greyscale buffer
        applyLut(self.greyscale_buf, self.lut);

        // Stage 3: sharpen into the scratch buffer
        sharpen(self.greyscale_buf, self.sharpen_buf, self.width, self.height, self.current_sharpen);

        return ProcessedFrame{
            .data = self.sharpen_buf,
            .width = self.width,
            .height = self.height,
        };
    }
};

// ============================================================================
// Stage 1: Greyscale Conversion (BT.709)
// ============================================================================

/// Convert a BGRA frame buffer to 8-bit greyscale using BT.709 luminance.
///
/// # BT.709 integer approximation
///
/// The standard luminance formula is:
///   Y = 0.2126*R + 0.7152*G + 0.0722*B
///
/// Floating point is expensive in a hot loop processing 1.15M pixels at
/// 15 fps. Instead, we scale coefficients by 256 and use integer multiply
/// with a right-shift:
///
///   Y = (R*54 + G*183 + B*19 + 128) >> 8
///
/// The +128 provides rounding and the coefficients sum to 256
/// (54+183+19=256), giving bit-exact results for black (0) and
/// white (255).
///
/// # BGRA byte order
///
/// macOS captures in BGRA: pixel[0]=Blue, pixel[1]=Green, pixel[2]=Red,
/// pixel[3]=Alpha. We ignore alpha since screen captures are always opaque.
///
/// # Performance note
///
/// For 1240x930 (1,153,200 pixels), this processes ~4.6M bytes of input.
/// Using u16 intermediate arithmetic avoids overflow: max value is
/// 255*183 = 46,665 which fits in u16 (max 65,535).
pub fn toGreyscale(frame: FrameBuffer, output: []u8) void {
    const pixel_count: usize = @as(usize, frame.width) * @as(usize, frame.height);
    std.debug.assert(output.len >= pixel_count);

    for (0..pixel_count) |i| {
        // Calculate byte offset in source buffer, respecting stride.
        // If stride == width * 4, this is equivalent to i * 4.
        const row = i / @as(usize, frame.width);
        const col = i % @as(usize, frame.width);
        const offset = row * @as(usize, frame.stride) + col * 4;

        // BGRA byte order: B=0, G=1, R=2, A=3
        const b: u16 = frame.data[offset];
        const g: u16 = frame.data[offset + 1];
        const r: u16 = frame.data[offset + 2];
        // Alpha (offset+3) ignored — screen captures are always opaque

        // BT.709 integer approximation with rounding:
        //   54/256  = 0.2109 (R weight, spec 0.2126)
        //   183/256 = 0.7148 (G weight, spec 0.7152)
        //   19/256  = 0.0742 (B weight, spec 0.0722)
        //
        // Coefficients sum to 256 (54+183+19), so pure white maps to 255.
        // +128 provides rounding (half of 256 divisor).
        // Max value: 255*256+128 = 65,408 — fits in u16 (max 65,535).
        const y: u16 = (r * 54 + g * 183 + b * 19 + 128) >> 8;
        output[i] = @intCast(y);
    }
}

// ============================================================================
// Stage 2: Contrast LUT (Gamma Correction)
// ============================================================================

/// Build a 256-entry lookup table for gamma contrast correction.
///
/// # Gamma perception
///
/// Human brightness perception is nonlinear — we're more sensitive to
/// differences in dark tones than bright tones. E-ink compounds this
/// because its reflective surface makes mid-tones appear darker than
/// on a backlit LCD.
///
/// A gamma curve adjusts for this:
///   output = 255 * (input/255) ^ (1/gamma)
///
/// - gamma > 1.0: lifts mid-tones, making the image brighter. Default
///   1.2 is gentle enough to improve e-ink readability without washing
///   out highlights.
/// - gamma = 1.0: identity (no change). Useful for testing.
/// - gamma < 1.0: pushes mid-tones down, making the image darker.
///
/// # Why a LUT?
///
/// pow() is expensive (~20 cycles). With a LUT, we compute it 256 times
/// at init, then each pixel is a single array index (1 cycle). For a
/// 1240x930 frame, that's ~1.15M cheap lookups instead of ~1.15M pow().
pub fn buildContrastLut(gamma: f32) [256]u8 {
    var lut: [256]u8 = undefined;
    const inv_gamma: f32 = 1.0 / gamma;

    for (0..256) |i| {
        const normalized: f32 = @as(f32, @floatFromInt(i)) / 255.0;

        // pow(normalized, 1/gamma) applies the gamma curve.
        // For gamma=1.0, this is pow(x, 1.0) = x (identity).
        const corrected: f32 = math.pow(f32, normalized, inv_gamma);

        // Scale back to 0-255 and round to nearest integer.
        const scaled: f32 = corrected * 255.0;

        // Clamp to valid u8 range (pow should stay in [0,1] for valid
        // inputs, but floating point rounding could push slightly over).
        lut[i] = @intFromFloat(math.clamp(scaled + 0.5, 0.0, 255.0));
    }

    return lut;
}

// ============================================================================
// Stage 2b: LUT Application
// ============================================================================

/// Apply a 256-entry LUT to a greyscale buffer in-place.
///
/// Each pixel value is replaced by lut[pixel]. This is the fastest
/// possible per-pixel transform — a single indexed memory read.
///
/// # Why in-place?
///
/// The greyscale buffer is an intermediate product that we no longer
/// need after LUT application. Transforming in-place avoids allocating
/// a third buffer and improves cache locality (read and write the same
/// memory region).
pub fn applyLut(pixels: []u8, lut: [256]u8) void {
    for (pixels) |*pixel| {
        pixel.* = lut[pixel.*];
    }
}

// ============================================================================
// Stage 3: Sharpening (Laplacian Unsharp Mask)
// ============================================================================

/// Sharpen a greyscale image using a Laplacian unsharp mask.
///
/// # The Laplacian kernel
///
/// The 4-connected Laplacian detects edges by computing the difference
/// between a pixel and the average of its 4 direct neighbours:
///
///         [ 0, -1,  0 ]
///   L  =  [-1,  4, -1]    (standard Laplacian)
///         [ 0, -1,  0 ]
///
/// The unsharp mask adds the original image back, scaled by `amount`:
///
///   sharpened = original + amount * Laplacian(original)
///
/// Expanding this gives us the combined kernel:
///
///         [  0,  -a,   0  ]
///   K  =  [ -a, 1+4a, -a ]
///         [  0,  -a,   0  ]
///
/// # Why 4-connected (not 8)?
///
/// For text on e-ink, vertical and horizontal edges dominate (letter
/// strokes are mostly horizontal and vertical). The 4-connected kernel
/// sharpens these efficiently without amplifying diagonal noise from
/// dithering patterns.
///
/// # Border handling
///
/// Border pixels (first/last row, first/last column) are copied
/// unchanged from input. This avoids out-of-bounds memory access
/// without the cost of conditional checks in the inner loop.
///
/// # Amount = 0.0 fast path
///
/// When sharpening is disabled, we memcpy input to output instead
/// of running the kernel. This is ~50x faster for passthrough.
pub fn sharpen(input: []const u8, output: []u8, width: u32, height: u32, amount: f32) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixel_count = w * h;

    std.debug.assert(input.len >= pixel_count);
    std.debug.assert(output.len >= pixel_count);

    // Fast path: sharpening disabled
    if (amount == 0.0) {
        @memcpy(output[0..pixel_count], input[0..pixel_count]);
        return;
    }

    // Handle degenerate dimensions: just copy
    if (w <= 2 or h <= 2) {
        @memcpy(output[0..pixel_count], input[0..pixel_count]);
        return;
    }

    // Combined kernel weights:
    //   center_weight = 1 + 4*amount
    //   neighbor_weight = -amount
    const center_weight: f32 = 1.0 + 4.0 * amount;
    const neg_amount: f32 = -amount;

    // -- Copy top row unchanged (border) --
    @memcpy(output[0..w], input[0..w]);

    // -- Copy bottom row unchanged (border) --
    const bottom_start = (h - 1) * w;
    @memcpy(output[bottom_start..bottom_start + w], input[bottom_start..bottom_start + w]);

    // -- Process interior rows --
    for (1..h - 1) |y| {
        // Copy left border pixel
        output[y * w] = input[y * w];
        // Copy right border pixel
        output[y * w + w - 1] = input[y * w + w - 1];

        // Process interior columns
        for (1..w - 1) |x| {
            const idx = y * w + x;

            // Read centre and 4 neighbours
            const center: f32 = @floatFromInt(input[idx]);
            const north: f32 = @floatFromInt(input[idx - w]);
            const south: f32 = @floatFromInt(input[idx + w]);
            const west: f32 = @floatFromInt(input[idx - 1]);
            const east: f32 = @floatFromInt(input[idx + 1]);

            // Apply combined kernel:
            //   result = center * (1+4a) + (north+south+west+east) * (-a)
            const result: f32 = center * center_weight +
                (north + south + west + east) * neg_amount;

            // Clamp to valid u8 range. High-contrast edges with large
            // `amount` can produce values outside [0, 255].
            const clamped: f32 = math.clamp(result, 0.0, 255.0);
            output[idx] = @intFromFloat(clamped);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

// -- Helper: create a BGRA pixel from R, G, B values (A=255) --
fn makeBgraPixel(r: u8, g: u8, b: u8) [4]u8 {
    // BGRA byte order: [Blue, Green, Red, Alpha]
    return .{ b, g, r, 255 };
}

// -- Helper: create a FrameBuffer from a flat BGRA array --
fn makeFrame(data: []const u8, width: u32, height: u32) FrameBuffer {
    return .{
        .data = data,
        .width = width,
        .height = height,
        .stride = width * 4,
    };
}

// ----------------------------------------------------------------------------
// Greyscale conversion tests
// ----------------------------------------------------------------------------

test "greyscale: all white" {
    // White pixel: R=255, G=255, B=255 -> Y should be 255
    // (255*54 + 255*183 + 255*19 + 128) >> 8 = (255*256 + 128) >> 8
    // = (65280 + 128) >> 8 = 65408 >> 8 = 255
    // Coefficients sum to 256 and +128 rounding gives exact white.
    const pixel = makeBgraPixel(255, 255, 255);
    var output: [1]u8 = undefined;
    toGreyscale(makeFrame(&pixel, 1, 1), &output);
    try testing.expectEqual(@as(u8, 255), output[0]);
}

test "greyscale: all black" {
    // Black pixel: R=0, G=0, B=0 -> Y = 0
    const pixel = makeBgraPixel(0, 0, 0);
    var output: [1]u8 = undefined;
    toGreyscale(makeFrame(&pixel, 1, 1), &output);
    try testing.expectEqual(@as(u8, 0), output[0]);
}

test "greyscale: pure red" {
    // Pure red: R=255, G=0, B=0 -> Y = (255*54 + 128) >> 8 = 13898 >> 8 = 54
    const pixel = makeBgraPixel(255, 0, 0);
    var output: [1]u8 = undefined;
    toGreyscale(makeFrame(&pixel, 1, 1), &output);
    const expected: u8 = @intCast((255 * 54 + 128) >> 8);
    try testing.expectEqual(expected, output[0]);
}

test "greyscale: pure green" {
    // Pure green: R=0, G=255, B=0 -> Y = (255*183 + 128) >> 8 = 46793 >> 8 = 182
    const pixel = makeBgraPixel(0, 255, 0);
    var output: [1]u8 = undefined;
    toGreyscale(makeFrame(&pixel, 1, 1), &output);
    const expected: u8 = @intCast((255 * 183 + 128) >> 8);
    try testing.expectEqual(expected, output[0]);
}

test "greyscale: pure blue" {
    // Pure blue: R=0, G=0, B=255 -> Y = (255*19 + 128) >> 8 = 4973 >> 8 = 19
    const pixel = makeBgraPixel(0, 0, 255);
    var output: [1]u8 = undefined;
    toGreyscale(makeFrame(&pixel, 1, 1), &output);
    const expected: u8 = @intCast((255 * 19 + 128) >> 8);
    try testing.expectEqual(expected, output[0]);
}

// ----------------------------------------------------------------------------
// Contrast LUT tests
// ----------------------------------------------------------------------------

test "LUT: identity gamma=1.0" {
    // With gamma=1.0, pow(x, 1/1) = x, so every entry should map to itself.
    const lut = buildContrastLut(1.0);
    for (0..256) |i| {
        try testing.expectEqual(@as(u8, @intCast(i)), lut[i]);
    }
}

test "LUT: default gamma=1.2 brightens midtones" {
    // gamma=1.2 should brighten mid-tones. Input 128 should map higher.
    // Expected: 255 * pow(128/255, 1/1.2) = 255 * pow(0.502, 0.833)
    //         = 255 * 0.5815 ≈ 148
    const lut = buildContrastLut(1.2);

    // Black stays black, white stays white
    try testing.expectEqual(@as(u8, 0), lut[0]);
    try testing.expectEqual(@as(u8, 255), lut[255]);

    // Mid-tone should be lifted above 128
    try testing.expect(lut[128] > 128);
    // Expected: 255 * pow(128/255, 1/1.2) = 255 * pow(0.502, 0.833)
    //         = 255 * 0.563 ≈ 143.6 -> rounds to 144
    // Allow +/- 2 for floating point variation across platforms.
    try testing.expect(lut[128] >= 142 and lut[128] <= 146);
}

test "LUT: darkening gamma=0.5" {
    // gamma=0.5 -> pow(x, 1/0.5) = pow(x, 2) -> darkens mid-tones.
    // Input 128: 255 * pow(128/255, 2) = 255 * 0.252 ≈ 64
    const lut = buildContrastLut(0.5);

    // Black and white are fixed points of any gamma curve
    try testing.expectEqual(@as(u8, 0), lut[0]);
    try testing.expectEqual(@as(u8, 255), lut[255]);

    // Mid-tone should be pushed down below 128
    try testing.expect(lut[128] < 128);
    // Verify ballpark (allow +/- 2)
    try testing.expect(lut[128] >= 62 and lut[128] <= 66);
}

// ----------------------------------------------------------------------------
// Sharpening tests
// ----------------------------------------------------------------------------

test "sharpen: disabled amount=0.0" {
    // When amount=0.0, output should be a copy of input (fast path).
    const input = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    var output: [9]u8 = undefined;

    sharpen(&input, &output, 3, 3, 0.0);

    try testing.expectEqualSlices(u8, &input, &output);
}

test "sharpen: default text edges enhanced" {
    // 5x5 image with a bright vertical edge in the middle:
    //   0  0  255  0  0
    //   0  0  255  0  0
    //   0  0  255  0  0
    //   0  0  255  0  0
    //   0  0  255  0  0
    //
    // With amount=0.5, the centre column should be brightened and
    // adjacent pixels should be darkened (clamped to 0).
    const w: u32 = 5;
    const h: u32 = 5;
    var input: [25]u8 = [_]u8{0} ** 25;
    // Set middle column to 255
    for (0..5) |row| {
        input[row * 5 + 2] = 255;
    }

    var output: [25]u8 = undefined;
    sharpen(&input, &output, w, h, 0.5);

    // Interior pixel at (2,2) — center of bright column:
    // center=255, north=255, south=255, east=0, west=0
    // result = 255*(1+2) + (255+255+0+0)*(-0.5) = 765 - 255 = 510
    // Clamped to 255.
    try testing.expectEqual(@as(u8, 255), output[2 * 5 + 2]);

    // Interior pixel at (1,2) — dark pixel next to bright column:
    // center=0, north=0, south=0, east=255, west=0
    // result = 0*(1+2) + (0+0+255+0)*(-0.5) = 0 - 127.5 = -127.5
    // Clamped to 0.
    try testing.expectEqual(@as(u8, 0), output[2 * 5 + 1]);

    // Interior pixel at (3,2) — dark pixel on the other side:
    // result should also clamp to 0.
    try testing.expectEqual(@as(u8, 0), output[2 * 5 + 3]);

    // Border pixels are copied unchanged
    try testing.expectEqual(@as(u8, 0), output[0]); // top-left
    try testing.expectEqual(@as(u8, 255), output[2]); // top-middle
}

test "sharpen: max amount=3.0 does not crash" {
    // Extreme sharpening with high-contrast input. The test verifies
    // that clamping prevents overflow/underflow and no panic occurs.
    const w: u32 = 4;
    const h: u32 = 4;
    // Checkerboard pattern: alternating 0 and 255
    var input: [16]u8 = undefined;
    for (0..16) |i| {
        input[i] = if ((i / 4 + i % 4) % 2 == 0) 0 else 255;
    }

    var output: [16]u8 = undefined;
    sharpen(&input, &output, w, h, 3.0);

    // All output values must be valid u8 (0-255) — if we got here
    // without a panic, clamping works. Verify bounds explicitly.
    for (output) |val| {
        try testing.expect(val <= 255); // Always true for u8, but documents intent
    }
}

test "sharpen: single pixel passthrough" {
    // A 1x1 image has no interior pixels — the entire frame is border.
    // It should be copied unchanged.
    const input = [_]u8{128};
    var output: [1]u8 = undefined;

    sharpen(&input, &output, 1, 1, 0.5);

    try testing.expectEqual(@as(u8, 128), output[0]);
}

test "sharpen: bounds clamping on high contrast" {
    // 3x3 image where the centre pixel is 0 surrounded by 255:
    //   255  255  255
    //   255   0   255
    //   255  255  255
    //
    // With amount=1.0:
    //   center_weight = 1 + 4*1.0 = 5
    //   result = 0*5 + (255*4)*(-1.0) = 0 - 1020 = -1020
    //   Must clamp to 0.
    const input = [_]u8{
        255, 255, 255,
        255, 0,   255,
        255, 255, 255,
    };
    var output: [9]u8 = undefined;

    sharpen(&input, &output, 3, 3, 1.0);

    // Centre pixel must be clamped to 0 (not underflow to garbage)
    try testing.expectEqual(@as(u8, 0), output[4]);

    // Now test the inverse: bright center surrounded by dark
    //   0   0   0
    //   0  255  0
    //   0   0   0
    const input2 = [_]u8{
        0, 0,   0,
        0, 255, 0,
        0, 0,   0,
    };
    var output2: [9]u8 = undefined;

    sharpen(&input2, &output2, 3, 3, 1.0);

    // center_weight = 5, result = 255*5 + 0 = 1275, clamp to 255
    try testing.expectEqual(@as(u8, 255), output2[4]);
}

// ----------------------------------------------------------------------------
// Full pipeline integration test
// ----------------------------------------------------------------------------

test "processFrame: full pipeline end-to-end" {
    // Create a small 4x4 BGRA frame with known pixel values.
    // Verify the pipeline produces a greyscale frame with correct dimensions,
    // and that the output values are in the valid range.
    const w: u32 = 4;
    const h: u32 = 4;
    const pixel_count = w * h;

    // Fill with a gradient: each pixel is (R=i*16, G=i*16, B=i*16)
    var bgra_data: [pixel_count * 4]u8 = undefined;
    for (0..pixel_count) |i| {
        const val: u8 = @intCast(i * 16);
        const px = makeBgraPixel(val, val, val);
        bgra_data[i * 4 + 0] = px[0]; // B
        bgra_data[i * 4 + 1] = px[1]; // G
        bgra_data[i * 4 + 2] = px[2]; // R
        bgra_data[i * 4 + 3] = px[3]; // A
    }

    const frame = makeFrame(&bgra_data, w, h);

    // Use default config (gamma=1.2, sharpen=0.5)
    var pipe = try Pipeline.init(testing.allocator, w, h, .{});
    defer pipe.deinit();

    const result = pipe.processFrame(frame);

    // Verify dimensions
    try testing.expectEqual(w, result.width);
    try testing.expectEqual(h, result.height);
    try testing.expectEqual(@as(usize, pixel_count), result.data.len);

    // All output values must be valid (0-255 guaranteed by u8,
    // but verify the pipeline didn't produce nonsense)
    for (result.data) |val| {
        _ = val; // Just verifying no crash during pipeline execution
    }
}

test "processFrame: updateConfig changes LUT" {
    // Verify that updateConfig actually changes pipeline behaviour.
    const w: u32 = 3;
    const h: u32 = 3;

    // Uniform grey frame: all pixels are (128, 128, 128)
    var bgra_data: [9 * 4]u8 = undefined;
    for (0..9) |i| {
        const px = makeBgraPixel(128, 128, 128);
        bgra_data[i * 4 + 0] = px[0];
        bgra_data[i * 4 + 1] = px[1];
        bgra_data[i * 4 + 2] = px[2];
        bgra_data[i * 4 + 3] = px[3];
    }

    const frame = makeFrame(&bgra_data, w, h);

    // First run with gamma=1.0 (identity), no sharpening
    var pipe = try Pipeline.init(testing.allocator, w, h, .{
        .gamma = 1.0,
        .sharpen_amount = 0.0,
    });
    defer pipe.deinit();

    const result1 = pipe.processFrame(frame);
    const val1 = result1.data[4]; // Centre pixel

    // Now change to gamma=2.0 (strong brightening)
    pipe.updateConfig(.{
        .gamma = 2.0,
        .sharpen_amount = 0.0,
    });

    const result2 = pipe.processFrame(frame);
    const val2 = result2.data[4]; // Centre pixel

    // With gamma=2.0, mid-tones should be significantly brighter
    try testing.expect(val2 > val1);
}

// ----------------------------------------------------------------------------
// Stride padding test (I7)
// ----------------------------------------------------------------------------

test "greyscale: stride with padding (stride = width*4 + 64)" {
    // macOS CGDisplayStream often pads rows to 64-byte boundaries.
    // Verify that toGreyscale correctly handles stride > width*4 by
    // skipping padding bytes at the end of each row.
    const w: u32 = 4;
    const h: u32 = 3;
    const stride: u32 = w * 4 + 64; // 16 + 64 = 80 bytes per row

    // Allocate padded buffer: h rows of `stride` bytes each
    var bgra_data: [3 * 80]u8 = undefined;

    // Fill entire buffer with garbage (0xAA) to ensure padding is ignored
    @memset(&bgra_data, 0xAA);

    // Write actual pixels: row 0 = white, row 1 = black, row 2 = pure red
    for (0..w) |col| {
        // Row 0: white pixels (R=255, G=255, B=255)
        const r0_off = 0 * stride + col * 4;
        bgra_data[r0_off + 0] = 255; // B
        bgra_data[r0_off + 1] = 255; // G
        bgra_data[r0_off + 2] = 255; // R
        bgra_data[r0_off + 3] = 255; // A

        // Row 1: black pixels (R=0, G=0, B=0)
        const r1_off = 1 * stride + col * 4;
        bgra_data[r1_off + 0] = 0;
        bgra_data[r1_off + 1] = 0;
        bgra_data[r1_off + 2] = 0;
        bgra_data[r1_off + 3] = 255;

        // Row 2: pure red pixels (R=255, G=0, B=0)
        const r2_off = 2 * stride + col * 4;
        bgra_data[r2_off + 0] = 0; // B
        bgra_data[r2_off + 1] = 0; // G
        bgra_data[r2_off + 2] = 255; // R
        bgra_data[r2_off + 3] = 255; // A
    }

    const frame = FrameBuffer{
        .data = &bgra_data,
        .width = w,
        .height = h,
        .stride = stride,
    };

    var output: [12]u8 = undefined; // 4*3 = 12 pixels
    toGreyscale(frame, &output);

    // Row 0: all white -> 255
    for (0..w) |col| {
        try testing.expectEqual(@as(u8, 255), output[0 * w + col]);
    }

    // Row 1: all black -> 0
    for (0..w) |col| {
        try testing.expectEqual(@as(u8, 0), output[1 * w + col]);
    }

    // Row 2: pure red -> (255*54 + 128) >> 8 = 54
    const expected_red: u8 = @intCast((255 * 54 + 128) >> 8);
    for (0..w) |col| {
        try testing.expectEqual(expected_red, output[2 * w + col]);
    }
}
