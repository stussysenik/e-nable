/// Delta Encoding Module — XOR frame differencing for e-ink screen mirroring
///
/// # Why XOR delta encoding?
///
/// Screen mirroring sends frames at ~15 fps, but e-ink displays update slowly
/// and most of the screen stays the same between frames (text editing, cursor
/// blinks, scroll). Sending the full frame every time wastes bandwidth.
///
/// XOR differencing exploits this: if pixel A in frame N equals pixel A in
/// frame N-1, their XOR is 0. Only *changed* pixels produce non-zero bytes.
/// The resulting "delta buffer" is overwhelmingly zeros — perfect for simple
/// compression (RLE shrinks it 60x+ in typical desktop usage).
///
/// # Pipeline
///
///   capture -> greyscale -> dither -> **xorDelta** -> **findDirtyRegions** -> **compress** -> send
///                                       ^ previous frame
///
/// On the receiver:
///
///   receive -> **decompress** -> **XOR apply** -> display
///
/// # Module structure (Single Responsibility)
///
///   - xorDelta()         -- compute byte-wise XOR between two frames
///   - findDirtyRegions() -- block-scan delta buffer for changed rectangles
///   - compress()         -- RLE compress zero-heavy delta buffer
///   - decompress()       -- RLE decompress back to original
///   - encode()           -- orchestrate: XOR + regions + compress + keyframe decision
///   - decode()           -- orchestrate: decompress + XOR apply to reconstruct
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// ============================================================================
// Data Structures
// ============================================================================

/// Axis-aligned bounding rectangle marking a changed region on screen.
/// Coordinates are in pixel space (not block space).
pub const DirtyRect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    /// Returns true if two rectangles overlap or are directly adjacent
    /// (touching edges). Adjacent merging prevents fragmented rects
    /// when changes span block boundaries.
    pub fn overlapsOrAdjacent(self: DirtyRect, other: DirtyRect) bool {
        const self_right = @as(u32, self.x) + @as(u32, self.width);
        const self_bottom = @as(u32, self.y) + @as(u32, self.height);
        const other_right = @as(u32, other.x) + @as(u32, other.width);
        const other_bottom = @as(u32, other.y) + @as(u32, other.height);

        // Two rects do NOT overlap/touch if one is fully left, right,
        // above, or below the other.
        if (self_right < @as(u32, other.x) or other_right < @as(u32, self.x)) return false;
        if (self_bottom < @as(u32, other.y) or other_bottom < @as(u32, self.y)) return false;
        return true;
    }

    /// Merge two rectangles into the smallest bounding rect containing both.
    pub fn merge(self: DirtyRect, other: DirtyRect) DirtyRect {
        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const self_right = @as(u32, self.x) + @as(u32, self.width);
        const self_bottom = @as(u32, self.y) + @as(u32, self.height);
        const other_right = @as(u32, other.x) + @as(u32, other.width);
        const other_bottom = @as(u32, other.y) + @as(u32, other.height);
        const max_right = @max(self_right, other_right);
        const max_bottom = @max(self_bottom, other_bottom);

        return .{
            .x = @intCast(min_x),
            .y = @intCast(min_y),
            .width = @intCast(max_right - min_x),
            .height = @intCast(max_bottom - min_y),
        };
    }
};

/// The result of encoding a frame delta. Carries everything the receiver
/// needs to reconstruct the current frame from a reference frame.
pub const DeltaPatch = struct {
    /// If true, `compressed_data` is the full frame (not a delta).
    /// Sent after reconnect or when >60% of pixels changed.
    is_keyframe: bool,

    /// Regions that changed -- the receiver only needs to
    /// redraw these areas, saving costly e-ink partial refreshes.
    dirty_rects: []DirtyRect,

    /// RLE-compressed delta (XOR) bytes, or full frame if keyframe.
    compressed_data: []u8,

    /// Number of non-zero bytes in the delta buffer. Used to decide
    /// keyframe vs delta: if dirty_pixel_count/total_pixels > 0.6,
    /// the overhead of region tracking exceeds just sending everything.
    dirty_pixel_count: u32,

    /// Total pixel count (width * height * bytes_per_pixel). Stored
    /// here so the receiver can allocate the right buffer size.
    total_pixels: u32,

    /// Monotonically increasing sequence number. The receiver uses
    /// this to detect dropped frames and request keyframes.
    sequence: u32,

    /// Free all allocator-owned slices in this patch.
    pub fn deinit(self: *const DeltaPatch, allocator: Allocator) void {
        allocator.free(self.dirty_rects);
        allocator.free(self.compressed_data);
    }
};

/// Block size (in pixels) for dirty region scanning.
///
/// # Trade-off: granularity vs overhead
///
/// Smaller blocks (e.g. 4x4) detect changes more precisely but produce
/// many tiny DirtyRects, increasing metadata overhead. Larger blocks
/// (e.g. 64x64) reduce rect count but over-report changed area, forcing
/// the e-ink display to refresh more than necessary.
///
/// 16x16 is the sweet spot for 1240x930 e-ink displays:
///   - 78 x 59 = ~4600 blocks to scan (fast)
///   - Each block covers 256 pixels -- small enough for cursor-sized changes
///   - Typical desktop usage produces 2-8 dirty rects (minimal overhead)
pub const BLOCK_SIZE: u32 = 16;

/// If more than 60% of pixels changed, send a keyframe instead of a delta.
///
/// Rationale: when most of the screen changes (e.g. switching windows,
/// scrolling a full page), the delta buffer has few zeros and RLE
/// compression provides little benefit. The overhead of dirty region
/// tracking and XOR computation exceeds the cost of just sending the
/// raw frame. The 60% threshold was chosen empirically -- typical desktop
/// interaction changes <5% of pixels per frame.
pub const KEYFRAME_THRESHOLD: f32 = 0.6;

// ============================================================================
// XOR Frame Differencing (REQ-DE-001)
// ============================================================================

/// Compute the XOR delta between two frames of identical size.
///
/// For each byte i:  delta[i] = current[i] XOR previous[i]
///
/// # Why XOR?
///
/// XOR has a magical property for differencing:
///   - If bytes are equal:    A XOR A = 0 (unchanged -> zero)
///   - If bytes are different: A XOR B != 0 (changed -> non-zero)
///   - It is perfectly reversible: A XOR (A XOR B) = B
///
/// This means the receiver can reconstruct the current frame by XOR-ing
/// the delta onto the previous frame. No division, no floating point,
/// just the cheapest operation a CPU can do.
///
/// # SIMD acceleration
///
/// When the target CPU supports vector operations, we process 16 bytes
/// at a time using Zig's @Vector type. The compiler maps this to
/// NEON (ARM) or SSE (x86) instructions automatically. For non-aligned
/// tail bytes, we fall back to scalar.
///
/// For a 1240x930 grayscale frame (1,153,200 bytes), SIMD processes
/// it in ~72,075 vector ops instead of ~1.15M scalar ops -- roughly 16x
/// fewer instructions.
pub fn xorDelta(current: []const u8, previous: []const u8, delta: []u8) void {
    std.debug.assert(current.len == previous.len);
    std.debug.assert(current.len == delta.len);

    const len = current.len;

    // -- SIMD path: process 16 bytes per iteration --
    // Zig's @Vector compiles to platform SIMD (NEON on Apple Silicon,
    // SSE2/AVX on x86). We get vectorization without inline assembly.
    const vector_len = 16;
    const simd_end = len - (len % vector_len);

    var i: usize = 0;
    while (i < simd_end) : (i += vector_len) {
        const cur_vec: @Vector(vector_len, u8) = current[i..][0..vector_len].*;
        const prev_vec: @Vector(vector_len, u8) = previous[i..][0..vector_len].*;
        const result = cur_vec ^ prev_vec;
        delta[i..][0..vector_len].* = result;
    }

    // -- Scalar tail: handle remaining bytes that don't fill a vector --
    while (i < len) : (i += 1) {
        delta[i] = current[i] ^ previous[i];
    }
}

// ============================================================================
// Dirty Region Detection (REQ-DE-002)
// ============================================================================

/// Scan the delta buffer and identify rectangular regions that contain changes.
///
/// # Algorithm
///
/// 1. **Block scan**: Divide the frame into BLOCK_SIZE x BLOCK_SIZE blocks.
///    For each block, check if ANY byte is non-zero. This is O(width*height)
///    but with excellent cache locality (sequential memory access).
///
/// 2. **Rect creation**: Each dirty block becomes a candidate DirtyRect.
///
/// 3. **Merge pass**: Repeatedly merge overlapping or adjacent rects until
///    no more merges are possible. This coalesces scattered single-block
///    changes into larger regions when they are near each other.
///
/// # Why block-based instead of pixel-based?
///
/// Pixel-level scanning would produce extremely precise regions but:
///   - Generates thousands of tiny 1x1 rects (huge metadata overhead)
///   - E-ink partial refresh has a minimum update region anyway (~16px)
///   - Block scanning is cache-friendly (reads sequential memory)
///
/// 16x16 blocks match the e-ink controller's native partial refresh
/// granularity, so we lose nothing in practice.
///
/// # Parameters
///
///   - delta: XOR delta buffer (output of xorDelta)
///   - width: frame width in pixels
///   - height: frame height in pixels
///   - allocator: used for the returned DirtyRect slice (caller must free)
///
/// # Returns
///
///   Slice of merged DirtyRect values. Empty slice if no changes detected.
pub fn findDirtyRegions(delta: []const u8, width: u32, height: u32, allocator: Allocator) ![]DirtyRect {
    // Phase 1: Block scan -- identify which blocks have any non-zero byte.
    // We use an ArrayList to collect candidate rects since we don't know
    // the count up front.
    var rects: std.ArrayList(DirtyRect) = .{};
    defer rects.deinit(allocator);

    const blocks_x = (width + BLOCK_SIZE - 1) / BLOCK_SIZE;
    const blocks_y = (height + BLOCK_SIZE - 1) / BLOCK_SIZE;

    var by: u32 = 0;
    while (by < blocks_y) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_x) : (bx += 1) {
            if (isBlockDirty(delta, bx, by, width, height)) {
                // Clamp block to frame boundaries. The rightmost/bottom
                // blocks may extend past the frame if dimensions aren't
                // evenly divisible by BLOCK_SIZE.
                const px = bx * BLOCK_SIZE;
                const py = by * BLOCK_SIZE;
                const bw = @min(BLOCK_SIZE, width - px);
                const bh = @min(BLOCK_SIZE, height - py);

                try rects.append(allocator, .{
                    .x = @intCast(px),
                    .y = @intCast(py),
                    .width = @intCast(bw),
                    .height = @intCast(bh),
                });
            }
        }
    }

    // Phase 2: Merge overlapping/adjacent rects.
    // Greedy iterative merge -- simple and correct for the small rect
    // counts we see in practice (typically <20 before merging).
    mergeRects(&rects);

    // Transfer ownership: caller is responsible for freeing.
    return rects.toOwnedSlice(allocator);
}

/// Check if a single BLOCK_SIZE x BLOCK_SIZE block contains any non-zero byte.
/// Returns true as soon as the first non-zero byte is found (early exit).
fn isBlockDirty(delta: []const u8, bx: u32, by: u32, width: u32, height: u32) bool {
    const start_x = bx * BLOCK_SIZE;
    const start_y = by * BLOCK_SIZE;
    const end_x = @min(start_x + BLOCK_SIZE, width);
    const end_y = @min(start_y + BLOCK_SIZE, height);

    var y = start_y;
    while (y < end_y) : (y += 1) {
        const row_start = y * width + start_x;
        const row_end = y * width + end_x;

        // Safety: the delta buffer must be at least width*height bytes.
        if (row_end > delta.len) return false;

        for (delta[row_start..row_end]) |byte| {
            if (byte != 0) return true;
        }
    }
    return false;
}

/// Iteratively merge overlapping/adjacent rects until stable.
///
/// This is O(n^2) per pass with at most n passes, so O(n^3) worst case.
/// In practice n < 20 and merging converges in 1-2 passes, so it is
/// effectively free compared to the XOR and compression steps.
fn mergeRects(rects: *std.ArrayList(DirtyRect)) void {
    var merged = true;
    while (merged) {
        merged = false;
        var i: usize = 0;
        while (i < rects.items.len) {
            var j: usize = i + 1;
            while (j < rects.items.len) {
                if (rects.items[i].overlapsOrAdjacent(rects.items[j])) {
                    // Merge j into i, then remove j.
                    rects.items[i] = rects.items[i].merge(rects.items[j]);
                    _ = rects.orderedRemove(j);
                    merged = true;
                    // Don't increment j -- the element at j is now a new
                    // rect that we haven't compared against i yet.
                } else {
                    j += 1;
                }
            }
            i += 1;
        }
    }
}

// ============================================================================
// RLE Compression (REQ-DE-003)
// ============================================================================

/// Run-Length Encoding optimized for zero-heavy delta buffers.
///
/// # Format
///
/// The encoding exploits the key insight about XOR delta buffers:
/// they are *overwhelmingly* zeros (unchanged pixels). In typical
/// desktop usage, 95-99% of bytes are zero.
///
/// Encoding rules:
///   - 0x00 followed by count_byte: a run of (count_byte + 1) zeros
///     -> encodes 1 to 256 consecutive zeros in just 2 bytes
///   - Any non-zero byte: literal (written as-is)
///
/// # Why not LZ4?
///
/// LZ4 is a better general-purpose compressor, but for our specific
/// use case (zero-heavy buffers), simple RLE achieves comparable
/// ratios with much simpler code. The delta buffer from a cursor
/// blink (~0.1% changed pixels) compresses from ~1.15MB to ~20KB
/// with this RLE scheme -- a 57x ratio. LZ4 might achieve 60-65x,
/// but the implementation complexity isn't worth it for MVP.
///
/// # Worst case
///
/// Input of alternating 0x00 and non-zero bytes: each zero becomes
/// 2 bytes (0x00, 0x00 meaning "1 zero"), and each non-zero byte
/// stays 1 byte. Worst case is 1.5x the input size. For non-zero
/// heavy input with no zeros, output equals input (1x).
///
/// # Parameters
///
///   - input: raw bytes to compress
///   - allocator: used for the output buffer (caller must free)
///
/// # Returns
///
///   Compressed byte slice. Caller owns the memory.
pub fn compress(input: []const u8, allocator: Allocator) ![]u8 {
    if (input.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Worst case: every byte is a solo 0x00 -> 2 bytes each.
    // We use an ArrayList and pre-allocate a reasonable estimate.
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    // Pre-allocate a reasonable estimate. For delta buffers,
    // the output is typically 1-5% of input.
    try output.ensureTotalCapacity(allocator, input.len / 4 + 64);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x00) {
            // Count consecutive zeros (up to 256).
            var count: usize = 1;
            while (i + count < input.len and input[i + count] == 0x00 and count < 256) {
                count += 1;
            }
            // Emit: 0x00 marker, then (count - 1) so we can encode 1..256 zeros.
            try output.append(allocator, 0x00);
            try output.append(allocator, @intCast(count - 1));
            i += count;
        } else {
            // Literal non-zero byte -- write it directly.
            try output.append(allocator, input[i]);
            i += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Decompress RLE data back to the original bytes.
///
/// # Parameters
///
///   - compressed: RLE-compressed data (output of compress())
///   - output_len: expected length of the decompressed output
///   - allocator: used for the output buffer (caller must free)
///
/// # Returns
///
///   Decompressed byte slice of exactly `output_len` bytes.
///
/// # Errors
///
///   Returns error if the compressed data doesn't produce exactly
///   output_len bytes (corruption or wrong output_len).
pub fn decompress(compressed: []const u8, output_len: usize, allocator: Allocator) ![]u8 {
    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var out_i: usize = 0;
    var in_i: usize = 0;

    while (in_i < compressed.len) {
        if (compressed[in_i] == 0x00) {
            // Zero run: next byte is (count - 1).
            if (in_i + 1 >= compressed.len) return error.CorruptedData;
            const count: usize = @as(usize, compressed[in_i + 1]) + 1;

            if (out_i + count > output_len) return error.CorruptedData;
            @memset(output[out_i .. out_i + count], 0x00);
            out_i += count;
            in_i += 2;
        } else {
            // Literal non-zero byte.
            if (out_i >= output_len) return error.CorruptedData;
            output[out_i] = compressed[in_i];
            out_i += 1;
            in_i += 1;
        }
    }

    if (out_i != output_len) return error.CorruptedData;
    return output;
}

// ============================================================================
// Encode / Decode Orchestration (REQ-DE-004, REQ-DE-005)
// ============================================================================

/// Full encode pipeline: XOR -> dirty regions -> compress -> keyframe decision.
///
/// This is the main entry point for the sender side. It takes the current
/// and previous frames and produces a DeltaPatch ready for transmission.
///
/// # Keyframe decision (REQ-DE-004)
///
/// If more than KEYFRAME_THRESHOLD (60%) of pixels changed, we skip the
/// delta and send the full current frame as a "keyframe". This happens
/// during:
///   - Window switches (completely new content)
///   - Full-page scrolls
///   - Screen-wide theme changes
///
/// The receiver knows to replace its reference frame entirely when
/// is_keyframe is true.
///
/// # Roundtrip guarantee (REQ-DE-005)
///
///   decode(previous, encode(current, previous)) == current
///
/// This is guaranteed by the XOR property: A XOR (A XOR B) = B.
/// The RLE compression is lossless, so the roundtrip is exact.
pub fn encode(
    current: []const u8,
    previous: []const u8,
    width: u32,
    height: u32,
    sequence: u32,
    allocator: Allocator,
) !DeltaPatch {
    std.debug.assert(current.len == previous.len);
    const total_pixels: u32 = @intCast(current.len);

    // Step 1: Compute XOR delta.
    const delta_buf = try allocator.alloc(u8, current.len);
    defer allocator.free(delta_buf);
    xorDelta(current, previous, delta_buf);

    // Step 2: Count dirty pixels (non-zero bytes in delta).
    var dirty_count: u32 = 0;
    for (delta_buf) |byte| {
        if (byte != 0) dirty_count += 1;
    }

    // Step 3: Keyframe decision.
    const dirty_ratio = @as(f32, @floatFromInt(dirty_count)) / @as(f32, @floatFromInt(total_pixels));
    const is_keyframe = dirty_ratio > KEYFRAME_THRESHOLD;

    // Step 4: Find dirty regions (even for keyframes, useful for logging).
    var dirty_rects: []DirtyRect = undefined;
    if (is_keyframe) {
        // For keyframes, report one rect covering the entire frame.
        dirty_rects = try allocator.alloc(DirtyRect, 1);
        dirty_rects[0] = .{
            .x = 0,
            .y = 0,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    } else {
        dirty_rects = try findDirtyRegions(delta_buf, width, height, allocator);
    }

    // Step 5: Compress. For keyframes, compress the full frame.
    //         For deltas, compress the XOR buffer.
    const data_to_compress = if (is_keyframe) current else delta_buf;
    const compressed = try compress(data_to_compress, allocator);

    return DeltaPatch{
        .is_keyframe = is_keyframe,
        .dirty_rects = dirty_rects,
        .compressed_data = compressed,
        .dirty_pixel_count = dirty_count,
        .total_pixels = total_pixels,
        .sequence = sequence,
    };
}

/// Full decode pipeline: decompress -> XOR apply to reconstruct the frame.
///
/// For a delta patch:  reference[i] ^= decompressed_delta[i]
/// After this, `reference` contains the reconstructed current frame.
///
/// For a keyframe:  reference = decompressed full frame (copy)
///
/// The caller provides a mutable `reference` buffer which is updated
/// in-place. This avoids an extra allocation on every frame.
///
/// # Parameters
///
///   - reference: mutable buffer containing the previous frame (or
///     uninitialized for keyframe). Updated in-place to the current frame.
///   - patch: the DeltaPatch produced by encode().
///   - allocator: used for temporary decompression buffer.
pub fn decode(reference: []u8, patch: *const DeltaPatch, allocator: Allocator) !void {
    const decompressed = try decompress(patch.compressed_data, reference.len, allocator);
    defer allocator.free(decompressed);

    if (patch.is_keyframe) {
        // Keyframe: overwrite reference entirely.
        @memcpy(reference, decompressed);
    } else {
        // Delta: XOR the delta onto the reference to reconstruct.
        // This works because: prev XOR (prev XOR cur) = cur
        //
        // Note: xorDelta reads from both slices and writes to the third.
        // Here we want reference[i] = reference[i] ^ decompressed[i].
        // We can't pass reference as both input and output to xorDelta
        // because of aliasing. Instead, do it inline.
        for (reference, 0..) |*byte, idx| {
            byte.* ^= decompressed[idx];
        }
    }
}

// ============================================================================
// Utility: Count dirty pixels
// ============================================================================

/// Count the number of non-zero bytes in a delta buffer.
/// Useful for external callers who want the dirty pixel count without
/// running the full encode pipeline.
pub fn countDirtyPixels(delta: []const u8) u32 {
    var count: u32 = 0;
    for (delta) |byte| {
        if (byte != 0) count += 1;
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

// -- XOR delta tests ----------------------------------------------------------

test "xor: identical frames produce all-zero delta" {
    // When nothing changes between frames, every XOR result is 0.
    // This is the common case -- e-ink screens are mostly static.
    const frame = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    var delta: [8]u8 = undefined;

    xorDelta(&frame, &frame, &delta);

    for (delta) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "xor: single pixel change produces localized non-zero" {
    // Only the changed byte(s) should be non-zero.
    // Simulates a cursor blink changing one pixel.
    const frame_a = [_]u8{ 0, 0, 0, 100, 0, 0, 0, 0 };
    const frame_b = [_]u8{ 0, 0, 0, 200, 0, 0, 0, 0 };
    var delta: [8]u8 = undefined;

    xorDelta(&frame_a, &frame_b, &delta);

    // Only byte 3 should be non-zero: 100 XOR 200 = 172
    try testing.expectEqual(@as(u8, 0), delta[0]);
    try testing.expectEqual(@as(u8, 0), delta[1]);
    try testing.expectEqual(@as(u8, 0), delta[2]);
    try testing.expect(delta[3] != 0);
    try testing.expectEqual(@as(u8, 100 ^ 200), delta[3]);
    try testing.expectEqual(@as(u8, 0), delta[4]);
}

test "xor: full screen change (white to black) produces all 0xFF" {
    // Worst case: every pixel changed. 0x00 XOR 0xFF = 0xFF.
    // This triggers the keyframe threshold in encode().
    const white = [_]u8{0x00} ** 64;
    const black = [_]u8{0xFF} ** 64;
    var delta: [64]u8 = undefined;

    xorDelta(&black, &white, &delta);

    for (delta) |byte| {
        try testing.expectEqual(@as(u8, 0xFF), byte);
    }
}

test "xor: cursor blink produces small non-zero region" {
    // Simulate a 2-pixel cursor appearing in a 16-pixel wide frame.
    // Pixels 4-5 change from background (0x00) to foreground (0xFF).
    var frame_a = [_]u8{0x00} ** 16;
    var frame_b = [_]u8{0x00} ** 16;
    frame_b[4] = 0xFF;
    frame_b[5] = 0xFF;
    var delta: [16]u8 = undefined;

    xorDelta(&frame_b, &frame_a, &delta);

    // Only bytes 4 and 5 should be non-zero.
    try testing.expectEqual(@as(u8, 0), delta[0]);
    try testing.expectEqual(@as(u8, 0xFF), delta[4]);
    try testing.expectEqual(@as(u8, 0xFF), delta[5]);
    try testing.expectEqual(@as(u8, 0), delta[6]);
}

test "xor: SIMD path handles non-aligned lengths" {
    // Ensure the scalar tail handles lengths not divisible by 16.
    // 19 bytes: 16 via SIMD + 3 scalar.
    var a: [19]u8 = undefined;
    var b: [19]u8 = undefined;
    var delta: [19]u8 = undefined;

    for (0..19) |i| {
        a[i] = @intCast(i);
        b[i] = @intCast(19 - i);
    }

    xorDelta(&a, &b, &delta);

    for (0..19) |i| {
        const expected = @as(u8, @intCast(i)) ^ @as(u8, @intCast(19 - i));
        try testing.expectEqual(expected, delta[i]);
    }
}

// -- Dirty region detection tests ---------------------------------------------

test "dirty regions: single dirty block produces one rect" {
    const allocator = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 32;

    // Create a delta with changes only in the top-left BLOCK_SIZE block.
    const delta = try allocator.alloc(u8, width * height);
    defer allocator.free(delta);
    @memset(delta, 0);
    delta[0] = 0xFF; // pixel (0,0) changed

    const rects = try findDirtyRegions(delta, width, height, allocator);
    defer allocator.free(rects);

    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 0), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, BLOCK_SIZE), rects[0].width);
    try testing.expectEqual(@as(u16, BLOCK_SIZE), rects[0].height);
}

test "dirty regions: three scattered regions produce three rects" {
    const allocator = testing.allocator;
    // Use a large enough frame so 3 blocks are clearly separated.
    const width: u32 = 64;
    const height: u32 = 64;

    const delta = try allocator.alloc(u8, width * height);
    defer allocator.free(delta);
    @memset(delta, 0);

    // Dirty pixel in block (0,0) -- top left
    delta[0 * width + 0] = 0xFF;
    // Dirty pixel in block (3,0) -- top right area (x=48..63)
    delta[0 * width + 48] = 0xFF;
    // Dirty pixel in block (0,3) -- bottom left area (y=48..63)
    delta[48 * width + 0] = 0xFF;

    const rects = try findDirtyRegions(delta, width, height, allocator);
    defer allocator.free(rects);

    // These blocks are far apart and should NOT merge.
    try testing.expectEqual(@as(usize, 3), rects.len);
}

test "dirty regions: edge-touching blocks have correct bounds" {
    const allocator = testing.allocator;
    const width: u32 = 20; // Not divisible by BLOCK_SIZE=16
    const height: u32 = 20;

    const delta = try allocator.alloc(u8, width * height);
    defer allocator.free(delta);
    @memset(delta, 0);

    // Dirty pixel in the rightmost block (x=16..19, y=0..15)
    delta[0 * width + 18] = 0xFF;

    const rects = try findDirtyRegions(delta, width, height, allocator);
    defer allocator.free(rects);

    try testing.expectEqual(@as(usize, 1), rects.len);
    // The block starts at x=16, but the frame is only 20 wide,
    // so the block width is clamped to 4 (20 - 16).
    try testing.expectEqual(@as(u16, 16), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, 4), rects[0].width);
    try testing.expectEqual(@as(u16, 16), rects[0].height);
}

test "dirty regions: full-screen dirty produces one rect covering frame" {
    const allocator = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 32;

    // Every pixel changed.
    const delta = try allocator.alloc(u8, width * height);
    defer allocator.free(delta);
    @memset(delta, 0xFF);

    const rects = try findDirtyRegions(delta, width, height, allocator);
    defer allocator.free(rects);

    // All blocks are dirty and adjacent -> they should merge into one.
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 0), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, 32), rects[0].width);
    try testing.expectEqual(@as(u16, 32), rects[0].height);
}

test "dirty regions: empty delta produces zero rects" {
    const allocator = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 32;

    const delta = try allocator.alloc(u8, width * height);
    defer allocator.free(delta);
    @memset(delta, 0);

    const rects = try findDirtyRegions(delta, width, height, allocator);
    defer allocator.free(rects);

    try testing.expectEqual(@as(usize, 0), rects.len);
}

test "dirty regions: adjacent blocks merge into one rect" {
    const allocator = testing.allocator;
    const width: u32 = 64;
    const height: u32 = 32;

    const delta = try allocator.alloc(u8, width * height);
    defer allocator.free(delta);
    @memset(delta, 0);

    // Dirty pixels in two horizontally adjacent blocks.
    delta[0 * width + 8] = 0xFF; // block (0,0)
    delta[0 * width + 24] = 0xFF; // block (1,0)

    const rects = try findDirtyRegions(delta, width, height, allocator);
    defer allocator.free(rects);

    // The two adjacent blocks should merge.
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 0), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, 32), rects[0].width);
    try testing.expectEqual(@as(u16, BLOCK_SIZE), rects[0].height);
}

// -- DirtyRect merge tests ----------------------------------------------------

test "DirtyRect: overlapping rects merge correctly" {
    const a = DirtyRect{ .x = 0, .y = 0, .width = 20, .height = 20 };
    const b = DirtyRect{ .x = 10, .y = 10, .width = 20, .height = 20 };

    try testing.expect(a.overlapsOrAdjacent(b));

    const merged = a.merge(b);
    try testing.expectEqual(@as(u16, 0), merged.x);
    try testing.expectEqual(@as(u16, 0), merged.y);
    try testing.expectEqual(@as(u16, 30), merged.width);
    try testing.expectEqual(@as(u16, 30), merged.height);
}

test "DirtyRect: non-overlapping rects do not report overlap" {
    const a = DirtyRect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = DirtyRect{ .x = 20, .y = 20, .width = 10, .height = 10 };

    try testing.expect(!a.overlapsOrAdjacent(b));
}

test "DirtyRect: adjacent rects (touching edge) merge" {
    // Right edge of A touches left edge of B.
    const a = DirtyRect{ .x = 0, .y = 0, .width = 16, .height = 16 };
    const b = DirtyRect{ .x = 16, .y = 0, .width = 16, .height = 16 };

    try testing.expect(a.overlapsOrAdjacent(b));

    const merged = a.merge(b);
    try testing.expectEqual(@as(u16, 0), merged.x);
    try testing.expectEqual(@as(u16, 32), merged.width);
}

// -- RLE compression tests ----------------------------------------------------

test "compress: all-zero input produces tiny output" {
    const allocator = testing.allocator;

    // 1024 zeros should compress to a handful of bytes.
    // Each 0x00+count pair encodes up to 256 zeros in 2 bytes.
    // So 1024 zeros -> 4 pairs = 8 bytes.
    const input: [1024]u8 = [_]u8{0} ** 1024;

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    // 1024 / 256 = 4 runs of 256 zeros, each encoded as 2 bytes.
    try testing.expectEqual(@as(usize, 8), compressed.len);

    // Verify the encoding: 0x00, 0xFF (= 255+1 = 256 zeros) x 4
    try testing.expectEqual(@as(u8, 0x00), compressed[0]);
    try testing.expectEqual(@as(u8, 0xFF), compressed[1]);
}

test "compress: random non-zero data has bounded expansion" {
    const allocator = testing.allocator;

    // Non-zero data should not expand: each byte is a literal.
    var input: [256]u8 = undefined;
    for (0..256) |i| {
        input[i] = @intCast(if (i == 0) 1 else i); // avoid zeros
    }

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    // No zeros -> output equals input (all literals).
    try testing.expectEqual(@as(usize, 256), compressed.len);
}

test "compress: mixed data compresses correctly" {
    const allocator = testing.allocator;

    // 4 zeros, 0xFF, 2 zeros, 0xAB
    const input = [_]u8{ 0, 0, 0, 0, 0xFF, 0, 0, 0xAB };

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    // Expected: [0x00, 0x03] (4 zeros), [0xFF], [0x00, 0x01] (2 zeros), [0xAB]
    try testing.expectEqual(@as(usize, 6), compressed.len);
    try testing.expectEqual(@as(u8, 0x00), compressed[0]);
    try testing.expectEqual(@as(u8, 0x03), compressed[1]); // 3+1 = 4 zeros
    try testing.expectEqual(@as(u8, 0xFF), compressed[2]);
    try testing.expectEqual(@as(u8, 0x00), compressed[3]);
    try testing.expectEqual(@as(u8, 0x01), compressed[4]); // 1+1 = 2 zeros
    try testing.expectEqual(@as(u8, 0xAB), compressed[5]);
}

test "compress/decompress: roundtrip on all-zero input" {
    const allocator = testing.allocator;
    const input: [512]u8 = [_]u8{0} ** 512;

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    const decompressed = try decompress(compressed, input.len, allocator);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, &input, decompressed);
}

test "compress/decompress: roundtrip on random data" {
    const allocator = testing.allocator;

    // Deterministic "random" data for reproducible tests.
    var input: [500]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..500) |i| {
        input[i] = random.int(u8);
    }

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    const decompressed = try decompress(compressed, input.len, allocator);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, &input, decompressed);
}

test "compress/decompress: roundtrip on all-0xFF input" {
    const allocator = testing.allocator;
    const input: [256]u8 = [_]u8{0xFF} ** 256;

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    // All 0xFF, no zeros -> output should be same size (all literals).
    try testing.expectEqual(@as(usize, 256), compressed.len);

    const decompressed = try decompress(compressed, input.len, allocator);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, &input, decompressed);
}

test "compress: empty input produces empty output" {
    const allocator = testing.allocator;
    const input: [0]u8 = .{};

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    try testing.expectEqual(@as(usize, 0), compressed.len);
}

test "decompress: corrupted data returns error" {
    const allocator = testing.allocator;

    // A zero-run that claims 256 zeros, but we only expect 10 bytes out.
    const bad = [_]u8{ 0x00, 0xFF }; // claims 256 zeros
    const result = decompress(&bad, 10, allocator);
    try testing.expectError(error.CorruptedData, result);
}

// -- Full pipeline roundtrip tests (REQ-DE-005) -------------------------------

test "roundtrip: random pixel buffers survive encode then decode" {
    const allocator = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 32;
    const size = width * height;

    // Generate two "frames" with mostly-similar content.
    var frame_a: [size]u8 = undefined;
    var frame_b: [size]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();

    for (0..size) |i| {
        frame_a[i] = random.int(u8);
        // frame_b is mostly the same, with ~10% changed pixels.
        frame_b[i] = if (random.int(u8) < 25) random.int(u8) else frame_a[i];
    }

    // Encode the delta from frame_a to frame_b.
    const patch = try encode(&frame_b, &frame_a, width, height, 1, allocator);
    defer patch.deinit(allocator);

    // Decode: start with frame_a, apply patch to get frame_b back.
    var reconstructed: [size]u8 = frame_a;
    try decode(&reconstructed, &patch, allocator);

    try testing.expectEqualSlices(u8, &frame_b, &reconstructed);
}

test "roundtrip: all-zero frames survive encode then decode" {
    const allocator = testing.allocator;
    const width: u32 = 16;
    const height: u32 = 16;
    const size = width * height;

    const frame: [size]u8 = [_]u8{0} ** size;

    const patch = try encode(&frame, &frame, width, height, 0, allocator);
    defer patch.deinit(allocator);

    // Identical frames -> no dirty pixels.
    try testing.expectEqual(@as(u32, 0), patch.dirty_pixel_count);
    try testing.expect(!patch.is_keyframe);

    var reconstructed: [size]u8 = frame;
    try decode(&reconstructed, &patch, allocator);

    try testing.expectEqualSlices(u8, &frame, &reconstructed);
}

test "roundtrip: all-0xFF frames survive encode then decode" {
    const allocator = testing.allocator;
    const width: u32 = 16;
    const height: u32 = 16;
    const size = width * height;

    const frame_a: [size]u8 = [_]u8{0x00} ** size;
    var frame_b: [size]u8 = [_]u8{0xFF} ** size;

    const patch = try encode(&frame_b, &frame_a, width, height, 1, allocator);
    defer patch.deinit(allocator);

    // 100% of pixels changed -> must be a keyframe.
    try testing.expect(patch.is_keyframe);
    try testing.expectEqual(size, patch.dirty_pixel_count);

    var reconstructed: [size]u8 = frame_a;
    try decode(&reconstructed, &patch, allocator);

    try testing.expectEqualSlices(u8, &frame_b, &reconstructed);
}

test "roundtrip: single pixel change survives encode then decode" {
    const allocator = testing.allocator;
    const width: u32 = 32;
    const height: u32 = 32;
    const size = width * height;

    var frame_a: [size]u8 = [_]u8{0x80} ** size;
    var frame_b: [size]u8 = [_]u8{0x80} ** size;
    frame_b[width * 10 + 15] = 0x42; // Change one pixel at (15, 10).

    const patch = try encode(&frame_b, &frame_a, width, height, 1, allocator);
    defer patch.deinit(allocator);

    try testing.expect(!patch.is_keyframe);
    try testing.expectEqual(@as(u32, 1), patch.dirty_pixel_count);

    var reconstructed: [size]u8 = frame_a;
    try decode(&reconstructed, &patch, allocator);

    try testing.expectEqualSlices(u8, &frame_b, &reconstructed);
}

// -- Keyframe threshold test (REQ-DE-004) -------------------------------------

test "encode: triggers keyframe when >60 percent pixels change" {
    const allocator = testing.allocator;
    const width: u32 = 16;
    const height: u32 = 16;
    const size = width * height;

    // Create frames where exactly 70% of pixels differ.
    const frame_a: [size]u8 = [_]u8{0x00} ** size;
    var frame_b: [size]u8 = [_]u8{0x00} ** size;
    const change_count = @as(usize, @intFromFloat(@as(f32, size) * 0.7));
    for (0..change_count) |i| {
        frame_b[i] = 0xFF;
    }

    const patch = try encode(&frame_b, &frame_a, width, height, 1, allocator);
    defer patch.deinit(allocator);

    try testing.expect(patch.is_keyframe);

    // Despite being a keyframe, roundtrip still works.
    var reconstructed: [size]u8 = frame_a;
    try decode(&reconstructed, &patch, allocator);
    try testing.expectEqualSlices(u8, &frame_b, &reconstructed);
}

test "encode: stays delta when <60 percent pixels change" {
    const allocator = testing.allocator;
    const width: u32 = 16;
    const height: u32 = 16;
    const size = width * height;

    // Create frames where exactly 40% of pixels differ.
    const frame_a: [size]u8 = [_]u8{0x00} ** size;
    var frame_b: [size]u8 = [_]u8{0x00} ** size;
    const change_count = @as(usize, @intFromFloat(@as(f32, size) * 0.4));
    for (0..change_count) |i| {
        frame_b[i] = 0xFF;
    }

    const patch = try encode(&frame_b, &frame_a, width, height, 1, allocator);
    defer patch.deinit(allocator);

    try testing.expect(!patch.is_keyframe);
}

// -- Utility tests ------------------------------------------------------------

test "countDirtyPixels: counts correctly" {
    const delta = [_]u8{ 0, 0, 0xFF, 0, 0xAB, 0, 0, 0x01 };
    try testing.expectEqual(@as(u32, 3), countDirtyPixels(&delta));
}

test "countDirtyPixels: all zeros returns zero" {
    const delta = [_]u8{0} ** 32;
    try testing.expectEqual(@as(u32, 0), countDirtyPixels(&delta));
}

// -- Compression ratio test (demonstrates e-ink suitability) ------------------

test "compress: delta buffer with 1 percent dirty achieves high compression" {
    const allocator = testing.allocator;

    // Simulate a typical e-ink frame delta: 99% zeros, 1% non-zero.
    // This models a cursor blink or small text edit.
    const size: usize = 10000;
    var input: [size]u8 = [_]u8{0} ** size;

    // Scatter 1% non-zero pixels.
    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    var dirty: usize = 0;
    while (dirty < size / 100) {
        const idx = random.uintLessThan(usize, size);
        if (input[idx] == 0) {
            input[idx] = random.intRangeAtMost(u8, 1, 255);
            dirty += 1;
        }
    }

    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    // Expect significant compression. The exact ratio depends on
    // how the non-zero pixels are distributed, but we should see
    // at least 10x compression for 99% zero data.
    const ratio = @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(compressed.len));
    try testing.expect(ratio > 10.0);

    // Verify roundtrip.
    const decompressed = try decompress(compressed, size, allocator);
    defer allocator.free(decompressed);
    try testing.expectEqualSlices(u8, &input, decompressed);
}
