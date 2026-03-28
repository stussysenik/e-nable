## ADDED Requirements

### Requirement: XOR Frame Differencing

The encoder MUST compute the XOR between consecutive processed frames to produce a delta buffer. XOR cleanly identifies changed pixels: unchanged pixels become zero, changed pixels become non-zero. This is the foundation for dirty region detection and compression.

**Acceptance Criteria:**
- Input: two frames of identical dimensions (current and previous)
- Output: delta buffer where each byte is current[i] XOR previous[i]
- Identical frames produce an all-zero delta
- Uses SIMD/Accelerate for vectorized XOR across the buffer

#### Scenario: Identical frames (empty delta)
**Given** frame A and frame B are pixel-identical
**When** XOR differencing is computed
**Then** the delta buffer is entirely zeros, and the system signals "no change" (skip transmission)

#### Scenario: Single pixel changed
**Given** frame A and frame B differ by exactly one pixel
**When** XOR differencing is computed
**Then** only the bytes corresponding to that pixel are non-zero in the delta buffer

#### Scenario: Cursor blink
**Given** frame A shows a text cursor and frame B hides it (cursor blink)
**When** XOR differencing is computed
**Then** only the pixels in the cursor region are non-zero, producing a small delta

#### Scenario: Full screen change
**Given** frame A is all-white and frame B is all-black
**When** XOR differencing is computed
**Then** every byte in the delta is 0xFF, representing a complete screen change

**Cross-references:** `image-pipeline`, `transport`

---

### Requirement: Dirty Region Detection

The encoder MUST identify rectangular regions containing changes from the XOR delta and pack them into a minimal set of bounding rectangles. This enables partial screen refresh on the e-ink display, avoiding full-screen redraws for small changes.

**Acceptance Criteria:**
- Scans delta buffer for non-zero regions
- Outputs a list of axis-aligned bounding rectangles covering all changes
- Merges overlapping or adjacent rectangles to minimize count
- Empty delta produces zero dirty regions

#### Scenario: Single dirty region
**Given** a delta buffer with changes concentrated in one rectangular area
**When** dirty region detection runs
**Then** exactly one bounding rectangle is returned that tightly encloses all changed pixels

#### Scenario: Multiple scattered regions
**Given** a delta buffer with changes in three separate screen areas (top-left, center, bottom-right)
**When** dirty region detection runs
**Then** three separate bounding rectangles are returned, one for each changed area

#### Scenario: Edge-touching regions
**Given** a delta buffer with changes along the left edge and top edge of the screen
**When** dirty region detection runs
**Then** bounding rectangles correctly extend to x=0 or y=0 without underflow errors

#### Scenario: Full-screen dirty
**Given** a delta buffer where every pixel has changed
**When** dirty region detection runs
**Then** a single bounding rectangle covering the entire screen is returned

**Cross-references:** `eink-renderer`

---

### Requirement: LZ4 Compression

The encoder SHALL compress delta patches using LZ4 for fast decompression on the Boox device. LZ4 is chosen for its decompression speed (>4 GB/s) which is critical for the resource-constrained Android-based e-ink device. XOR deltas compress extremely well because unchanged regions are long runs of zeros.

**Acceptance Criteria:**
- Uses LZ4 frame format for streaming decompression
- Typical delta achieves >60x compression ratio (mostly zeros)
- Decompression is lossless and produces byte-identical output
- Compression level optimized for speed over ratio

#### Scenario: Typical delta (>60x compression)
**Given** a delta buffer where ~5% of pixels changed (cursor blink + small text edit)
**When** LZ4 compression is applied
**Then** compressed size is <2% of raw delta size (>60x reduction due to zero runs)

#### Scenario: Empty delta (trivial compression)
**Given** a delta buffer that is entirely zeros (no changes)
**When** LZ4 compression is applied
**Then** compressed output is minimal (header only, <50 bytes) and decompresses to the all-zero buffer

#### Scenario: All-changed frame (worst case)
**Given** a delta buffer where every pixel changed (random data)
**When** LZ4 compression is applied
**Then** compressed size is at most 1.004x the raw size (LZ4 worst case) and decompression produces identical output

#### Scenario: Roundtrip verification
**Given** any arbitrary delta buffer
**When** LZ4 compress then decompress is applied
**Then** the decompressed output is byte-identical to the original input

**Cross-references:** `transport`

---

### Requirement: Full-Frame Fallback

The system MUST send a full keyframe instead of a delta when more than 60% of pixels have changed. In this case, the delta is larger than a compressed keyframe and provides no benefit. Keyframes are also sent after reconnection and periodically to prevent error accumulation.

**Acceptance Criteria:**
- Threshold: if dirty pixels > 60% of total pixels, send keyframe
- Keyframe is the full processed frame, LZ4 compressed
- Keyframe flag is set in the transport protocol header
- After reconnect, first frame is always a keyframe
- Periodic forced keyframe every N seconds (configurable, default 60s)

#### Scenario: Threshold crossing
**Given** the user switches browser tabs causing 75% of pixels to change
**When** delta encoding evaluates the change
**Then** the system sends a full keyframe instead of a delta, and the keyframe flag is set in the header

#### Scenario: Keyframe after reconnect
**Given** the transport connection was lost and re-established
**When** the first frame is ready to send
**Then** a full keyframe is sent regardless of the delta size, ensuring the client has a complete reference frame

#### Scenario: Periodic forced keyframe
**Given** mirroring has been active for 60 seconds with only small deltas
**When** the periodic keyframe timer fires
**Then** the next frame is sent as a full keyframe to clear any accumulated decode drift

**Cross-references:** `transport`

---

### Requirement: Roundtrip Integrity

The delta encoding/decoding pipeline MUST be lossless. Given frame_a and frame_b, encode(frame_a, frame_b) produces a delta, and decode(frame_a, delta) must reproduce frame_b exactly, byte-for-byte.

**Acceptance Criteria:**
- decode(frame_a, encode(frame_a, frame_b)) == frame_b for all valid inputs
- Verified with property-based testing across random pixel buffers
- Edge cases (all zeros, all ones) produce correct roundtrips
- Works for all supported frame sizes

#### Scenario: Random pixel buffers
**Given** frame_a and frame_b are random pixel buffers of size 1240x930
**When** delta = encode(frame_a, frame_b), then result = decode(frame_a, delta)
**Then** result is byte-identical to frame_b

#### Scenario: Edge case -- all zeros
**Given** frame_a is all zeros and frame_b is all zeros
**When** delta = encode(frame_a, frame_b), then result = decode(frame_a, delta)
**Then** result is all zeros (byte-identical to frame_b)

#### Scenario: Edge case -- all ones
**Given** frame_a is all 0xFF and frame_b is all 0xFF
**When** delta = encode(frame_a, frame_b), then result = decode(frame_a, delta)
**Then** result is all 0xFF (byte-identical to frame_b)

#### Scenario: Large frames
**Given** frame_a and frame_b are 2480x1860 pixel buffers (largest supported resolution)
**When** delta = encode(frame_a, frame_b), then result = decode(frame_a, delta)
**Then** result is byte-identical to frame_b and encoding + decoding completes within latency budget

**Cross-references:** `eink-renderer`
