# Design: e-nable Mac-to-Boox E-Ink Screen Mirror

Cross-cutting architectural decisions for the e-nable system. This document defines module boundaries, data contracts, FFI strategy, wire protocol, e-ink refresh management, and performance targets. Every decision is grounded in research of the Daylight Mirror codebase and Boox SDK.

---

## 1. System Overview

```
Mac (Swift + Zig)           USB-C / ADB           Boox (Kotlin + Zig)
+--------------------+                          +--------------------+
| ScreenCaptureKit   |-->  Zig Pipeline  --> ADB -->  Zig Renderer   |
| Virtual Display    |     (greyscale,          | (BSR refresh,      |
|                    |      dither, delta)       |  partial update)   |
| Input Injector   <--------- ADB <------------ Input Capture       |
| (CGEvent)          |                          | (Wacom digitizer)  |
+--------------------+                          +--------------------+
```

Frames flow Mac-to-Boox. Input events flow Boox-to-Mac. Both share a single bidirectional ADB socket tunnel over USB-C. The Zig core library compiles once and runs on both platforms via C ABI.

---

## 2. Module Boundary Contracts

Modules communicate through five data types. These are the only structures that cross module boundaries. No module reaches into another's internals.

### 2.1 `FrameBuffer`

Flows from **capture** to **pipeline**.

```
FrameBuffer {
    pixels: [*]u8,        // Raw BGRA pixel data, row-major
    width: u32,           // Frame width in pixels
    height: u32,          // Frame height in pixels
    stride: u32,          // Bytes per row (may include padding)
    timestamp: u64,       // Monotonic nanoseconds
}
```

- Allocated by the capture module using `IOSurface`-backed memory
- The pipeline borrows this buffer (no copy) and returns it when done
- BGRA byte order matches `ScreenCaptureKit` output directly (no swizzle needed)

### 2.2 `ProcessedFrame`

Flows from **pipeline** to **delta**.

```
ProcessedFrame {
    pixels: [*]u8,        // Greyscale (1 byte/px) or quantized color (2 bytes/px)
    width: u32,
    height: u32,
    mode: enum { bw, color },
    timestamp: u64,
}
```

- In B&W mode: 8-bit greyscale, Atkinson-dithered to 16 shades (4 bits effective, stored as 8 for alignment)
- In Color mode: 12-bit RGB (4 bits per channel), packed into 16-bit words matching Kaleido 3's 4096-color gamut
- The pipeline owns this buffer and reuses it across frames (double-buffered: current + previous)

### 2.3 `DeltaPatch`

Flows from **delta** to **transport** (Mac side) and from **transport** to **renderer** (Boox side).

```
DeltaPatch {
    sequence: u32,                 // Monotonically increasing frame number
    is_keyframe: bool,             // If true, payload is a full frame (no delta)
    dirty_rects: []DirtyRect,      // Changed regions
    compressed_payload: []u8,      // LZ4-compressed pixel data for all dirty rects
    total_dirty_pixels: u32,       // Sum of all rect areas (for refresh mode decision)
    total_pixels: u32,             // Total frame pixels (width * height)
}

DirtyRect {
    x: u16,                        // Top-left X in pixels
    y: u16,                        // Top-left Y in pixels
    w: u16,                        // Width in pixels
    h: u16,                        // Height in pixels
}
```

- Dirty rects are axis-aligned, non-overlapping, merged when adjacent
- The compressed payload contains pixel data for all dirty rects concatenated in order, then LZ4-compressed as a single block
- A keyframe is sent on first connection, after reconnect, and when dirty percentage exceeds 60%
- When no pixels change between frames, `dirty_rects` is empty and nothing is sent over the wire

### 2.4 `ControlMessage`

Flows bidirectionally over the transport channel.

```
ControlMessage = enum {
    mode_switch { target: enum { bw, color } },
    resolution_change { width: u32, height: u32 },
    brightness { value: u8 },              // 0-255
    sharpening { value: f32 },             // 0.0-3.0
    contrast { gamma: f32 },               // 0.5-2.0
    ghost_clear_interval { frames: u16 },  // 0 = disabled
    force_full_refresh,
    request_keyframe,
    ping { client_timestamp: u64 },
    pong { client_timestamp: u64, server_timestamp: u64 },
    shutdown,
}
```

- Control messages are multiplexed on the same TCP connection as frame data (distinguished by a flag byte in the header)
- Ping/pong is used for RTT measurement and connection health monitoring
- All settings changes take effect on the next frame (no mid-frame mutation)

### 2.5 `InputEvent`

Flows from **Boox input capture** to **Mac input injector**.

```
InputEvent {
    type: enum { stylus_down, stylus_move, stylus_up, touch_down, touch_move, touch_up },
    x: f32,              // Normalized 0.0-1.0 (left to right)
    y: f32,              // Normalized 0.0-1.0 (top to bottom)
    pressure: f32,       // 0.0-1.0 (4096 levels from Wacom EMR)
    tilt_x: f32,         // Radians, -PI/2 to PI/2
    tilt_y: f32,         // Radians, -PI/2 to PI/2
    timestamp: u64,      // Device monotonic nanoseconds
}
```

- Coordinates are normalized so the Mac side can map them to any virtual display resolution
- Pressure and tilt come from the Boox's Wacom EMR digitizer (`getPressure()`, `getAxisValue(TILT_X/Y)`)
- On Mac, these are injected as `CGEvent` tablet events via `CGEventCreateMouseEvent` with `CGEventSetDoubleValueField` for pressure/tilt
- Stale input events (>100ms old when received) are dropped, not queued

---

## 3. Zig FFI Strategy

The Zig core (`zig-core/`) contains all pixel processing and delta encoding logic. It compiles to a C ABI shared library that both platforms consume.

### 3.1 Export Surface

All FFI functions live in `zig-core/src/ffi.zig` and use `export` to produce C-linkage symbols:

```zig
// ffi.zig -- C ABI boundary
export fn enable_pipeline_process(
    src: [*]const u8,    // BGRA input
    dst: [*]u8,          // greyscale/color output
    width: u32,
    height: u32,
    stride: u32,
    mode: c_int,         // 0 = bw, 1 = color
) callconv(.C) c_int;

export fn enable_delta_encode(
    prev: [*]const u8,
    curr: [*]const u8,
    width: u32,
    height: u32,
    out_buf: [*]u8,
    out_buf_len: u32,
) callconv(.C) c_int;    // Returns bytes written, -1 on error

export fn enable_delta_decode(
    base: [*]u8,          // Modified in-place
    patch: [*]const u8,
    patch_len: u32,
    width: u32,
    height: u32,
) callconv(.C) c_int;
```

Design rules for the FFI boundary:

- **No Zig allocator crosses the boundary.** All buffers are allocated by the caller (Swift or Kotlin/JNI) and passed in. Zig operates on borrowed memory only.
- **Error codes, not exceptions.** Functions return `c_int` (0 = success, negative = error code). No panics escape the FFI boundary; `@panic` is caught and converted to an error return.
- **No Zig-specific types in signatures.** Only C-compatible primitives: `[*]u8`, `u32`, `c_int`, `f32`. Structs exposed to C use `extern struct` with explicit layout.
- **Thread safety.** Each FFI call is stateless and reentrant. Pipeline state (previous frame buffer, LUT tables) is held in an opaque context pointer allocated via `enable_context_create()` / `enable_context_destroy()`.

### 3.2 macOS Integration (Swift)

Swift calls Zig via a C bridging header, following the same pattern Daylight Mirror uses for its C image processing code:

```
macos/
  Sources/
    ZigBridge/
      include/
        enable_core.h       // C header declaring Zig exports
      enable_bridge.swift   // Swift wrapper with safe types
```

- `enable_core.h` is auto-generated from `ffi.zig` annotations (or hand-maintained -- at this scale, hand-maintained is simpler)
- The Swift wrapper converts `IOSurface` pixel pointers to `UnsafeMutablePointer<UInt8>` for Zig
- The Zig library is linked as a dynamic library (`libenable_core.dylib`) via the Swift Package Manager

### 3.3 Android Integration (Kotlin via JNI)

Kotlin calls Zig through a thin C JNI bridge:

```
android/app/src/main/jni/
  zig_bridge.c              // JNI_OnLoad, native method implementations
```

The JNI bridge:
1. Receives `ByteBuffer` from Kotlin (direct buffer, no copy)
2. Extracts the native pointer via `GetDirectBufferAddress`
3. Calls the Zig `export` function
4. Returns result to Kotlin

This is a thin translation layer only -- no logic lives in the C bridge.

### 3.4 Cross-Compilation

The same Zig source compiles for both platforms:

```zig
// build.zig targets
const targets = .{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },          // Apple Silicon Mac
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android },  // Boox (ARM64 Android)
};
```

`zig build` produces both `libenable_core.dylib` (macOS) and `libenable_core.so` (Android) from one invocation. The Makefile orchestrates this before building either platform's app.

---

## 4. Build System

### 4.1 Orchestration

The top-level `Makefile` is the single entry point:

```makefile
all: zig-core macos android

zig-core:               # Cross-compiles for macOS + Android
    cd zig-core && zig build

macos: zig-core          # Links libenable_core.dylib
    cd macos && swift build

android: zig-core        # Includes libenable_core.so via JNI
    cd android && ./gradlew assembleDebug
```

### 4.2 Zig Build

`zig-core/build.zig` handles:

- **Two output artifacts**: `.dylib` for macOS, `.so` for Android (both from the same source)
- **LZ4**: Vendored as a Zig package or compiled from C source via `@cImport` (Zig's built-in C interop)
- **SIMD**: Pipeline functions use Zig's `@Vector` types which auto-lower to NEON on ARM64
- **Test step**: `zig build test` runs all unit tests with a built-in test runner

### 4.3 Platform Builds

- **macOS**: Swift Package Manager. The package manifest declares a system library dependency on `libenable_core` and links it. The dylib is copied into the app bundle at build time.
- **Android**: Gradle with the NDK. The `.so` is placed in `app/src/main/jniLibs/arm64-v8a/`. The JNI bridge C file is compiled by CMake (standard NDK toolchain).

### 4.4 Developer Workflow

```bash
make all          # Build everything
make test         # Run all test suites (Zig + Swift + Android)
make zig-core     # Rebuild just the Zig library
make clean        # Remove all build artifacts
```

No IDE required. The full project builds from a terminal with `make all` assuming Zig, Swift, and Android SDK are installed.

---

## 5. Binary Protocol

### 5.1 Wire Format

Derived from Daylight Mirror's length-prefixed TCP protocol, extended with flags for our additional capabilities:

```
Header (11 bytes):
  +--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+
  | Magic (2B)      | Flags  | Sequence (4B LE)                  | Length (4B LE)                    |
  | 0xDA   | 0x7E   | 1 byte | seq[0] | seq[1] | seq[2] | seq[3]| len[0] | len[1] | len[2] | len[3]|
  +--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+

Flags byte:
  bit 0: keyframe (1 = full frame, 0 = delta)
  bit 1: color mode (1 = color, 0 = B&W)
  bit 2: has_input (1 = payload contains input events)
  bit 3: is_control (1 = payload is a ControlMessage)
  bits 4-7: reserved (must be 0)

Payload:
  [Length bytes of compressed frame/delta/control/input data]
```

### 5.2 Packet Types

| Flags Pattern | Meaning | Payload |
|---------------|---------|---------|
| `0b0000_0000` | B&W delta frame | LZ4-compressed dirty rects + pixel data |
| `0b0000_0001` | B&W keyframe | LZ4-compressed full frame |
| `0b0000_0010` | Color delta frame | LZ4-compressed dirty rects + pixel data |
| `0b0000_0011` | Color keyframe | LZ4-compressed full frame |
| `0b0000_0100` | Input events | Serialized `InputEvent` array |
| `0b0000_1000` | Control message | Serialized `ControlMessage` |

### 5.3 ACK Packets

The receiver sends a 6-byte ACK after processing each frame:

```
ACK (6 bytes):
  +--------+--------+--------+--------+--------+--------+
  | Magic (2B)      | Sequence (4B LE)                  |
  | 0xDA   | 0x7E   | seq[0] | seq[1] | seq[2] | seq[3]|
  +--------+--------+--------+--------+--------+--------+
```

ACKs serve two purposes:
1. **Flow control**: The sender does not push the next frame until the previous ACK arrives (or a timeout expires). This naturally rate-limits to the e-ink display's refresh speed.
2. **RTT tracking**: The sender timestamps each frame internally and measures round-trip time from the ACK. If RTT exceeds a threshold (default: 500ms), the sender backs off.

### 5.4 Transport Configuration

- **TCP with `TCP_NODELAY`**: Disables Nagle's algorithm. Critical for low-latency delivery of small delta packets. Daylight Mirror uses this and achieves ~2ms transport latency over USB.
- **ADB reverse tunnel**: `adb reverse tcp:7470 tcp:7470` maps a port on the Boox to the Mac. The Boox app connects to `localhost:7470` which tunnels to the Mac over USB-C.
- **Single connection, multiplexed**: Frames, control messages, and input events share one TCP connection. The flags byte distinguishes packet types. This avoids head-of-line blocking between channels since packets are small and infrequent relative to the link speed.

---

## 6. E-Ink Refresh Strategy

E-ink refresh is the dominant latency in the system (200-600ms vs. <12ms for the entire pipeline). The refresh strategy directly determines perceived responsiveness.

### 6.1 Boox BSR Refresh Modes

From the Boox SDK (`EpdController`):

| Mode | Latency | Visual Quality | Ghost Artifacts | Use Case |
|------|---------|---------------|-----------------|----------|
| **DW** (Direct Waveform) | ~200ms | Moderate -- some loss of grey levels | Accumulates over time | Cursor movement, text editing, small UI changes |
| **GU** (Grey Update) | ~600ms | Good -- full grey range preserved | Minimal per-refresh | Scrolling, window switching, moderate content changes |
| **GC** (Global Clear) | ~600ms | Best -- full black-to-white-to-black flash | None (clears all ghosts) | Periodic cleanup, mode switches, large content changes |

### 6.2 Mode Selection Algorithm

The renderer selects a refresh mode based on the `DeltaPatch` metadata:

```
dirty_percentage = total_dirty_pixels / total_pixels * 100

if dirty_percentage == 0:
    // No change -- skip refresh entirely
    return

if dirty_percentage < 10:
    mode = DW      // Fast partial refresh for small changes
else if dirty_percentage <= 60:
    mode = GU      // Moderate refresh for medium changes
else:
    mode = GC      // Full refresh -- also counts as ghost clear

if frames_since_last_gc >= ghost_clear_interval:
    mode = GC      // Periodic ghost clearing
    frames_since_last_gc = 0
```

### 6.3 Ghost Mitigation

E-ink panels retain faint traces of previous content ("ghosting"). The mitigation strategy:

- **Periodic GC refresh**: Every N frames (default: 30, configurable via `ControlMessage.ghost_clear_interval`), force a GC refresh regardless of dirty percentage
- **GC on mode switch**: When toggling between B&W and Color, always do a GC refresh to clear artifacts from the previous mode's dithering pattern
- **GC on reconnect**: After transport reconnection, the first keyframe triggers a GC refresh
- **User-triggered**: The `force_full_refresh` control message triggers an immediate GC

### 6.4 Partial Refresh Regions

When using DW or GU mode, the renderer passes dirty rects to `EpdController.invalidate(view, mode, rect)` to refresh only the changed regions. This is faster than refreshing the full screen:

- Small dirty region (e.g., cursor blink): 200ms DW on a 20x20 pixel rect
- Medium dirty region (e.g., line of text): 200ms DW on a 800x30 pixel rect
- Full screen: 600ms GU/GC on the entire 1240x930 area

The dirty rects from `DeltaPatch` map directly to partial refresh regions. No additional calculation needed on the renderer side.

---

## 7. Adaptive Frame Rate

### 7.1 Problem

E-ink cannot display frames faster than its refresh cycle allows. Pushing 30fps to a display that takes 200ms to refresh wastes CPU, battery, and bandwidth while providing zero visual benefit.

### 7.2 ACK-Gated Pipeline

The frame rate is self-regulating through the ACK mechanism:

```
1. Capture frame
2. Process through pipeline (greyscale, dither, delta)
3. Send DeltaPatch over transport
4. WAIT for ACK from renderer
5. ACK arrives (meaning: e-ink refresh complete, ready for next frame)
6. Go to 1
```

This naturally adapts to the display's capability:
- **DW mode (200ms refresh)**: Effective rate ~5fps
- **GU/GC mode (600ms refresh)**: Effective rate ~1.7fps
- **No content change**: No frame sent, no ACK needed, zero CPU usage

### 7.3 Capture Pacing

On the Mac side, `ScreenCaptureKit` delivers frames at the compositor rate (~60fps). Since we cannot consume them that fast:

- The capture module keeps only the **latest** frame, dropping intermediate frames
- When the pipeline finishes and the transport ACK returns, the capture module provides whatever the most recent frame is
- This means we always send the freshest content, never stale buffered frames

### 7.4 CompositorPacer

Adopted from Daylight Mirror: a 4x4 pixel window alternates between black and near-black (#000001) to force the macOS compositor to redraw the virtual display at 60Hz. Without this trick, the compositor may skip frames for "unchanged" displays. The window is invisible to the user but keeps the frame pipeline fed.

---

## 8. Error Handling

### 8.1 Capture Errors

| Error | Recovery |
|-------|----------|
| `ScreenCaptureKit` frame acquisition fails | Retry on next compositor tick. Log error but do not crash. |
| Virtual display lost (user changed display config) | Recreate virtual display with current resolution settings. Send keyframe on next cycle. |
| Screen Recording permission revoked | Surface error to user via menu bar app. Pause pipeline until re-granted. |

### 8.2 Transport Errors

| Error | Recovery |
|-------|----------|
| TCP connection dropped | Auto-reconnect with exponential backoff: 100ms, 200ms, 400ms, ... up to 5s max. |
| Reconnection succeeds | Send a keyframe immediately (renderer has no valid previous frame). |
| ACK timeout (>2s) | Assume connection lost. Trigger reconnection flow. |
| ADB tunnel not found | Retry `adb reverse` setup. Surface error to user if ADB is not available. |

### 8.3 Renderer Errors

| Error | Recovery |
|-------|----------|
| `EpdController.invalidate()` fails on partial refresh | Fallback to GC (full refresh) mode for this frame. Log the failure. |
| Decompression error (corrupt data) | Request keyframe from Mac via `ControlMessage.request_keyframe`. |
| Buffer allocation failure | Drop frame. The next frame will be processed when memory is available. |

### 8.4 Input Errors

| Error | Recovery |
|-------|----------|
| Input event arrives >100ms stale (high latency) | Drop the event. Stale stylus input causes erratic cursor behavior. |
| Wacom digitizer unavailable | Fall back to capacitive touch only. Log warning. |
| CGEvent injection fails on Mac | Log error. Do not retry -- the event is already stale. |

---

## 9. Performance Budget

### 9.1 Pipeline Targets

| Stage | Owner | Target | Daylight Mirror Actual | Notes |
|-------|-------|--------|----------------------|-------|
| Screen capture | Swift | <1ms | ~0.5ms | `IOSurface` zero-copy from compositor |
| Greyscale + dither | Zig | <3ms | 0.2ms (no dither) | Atkinson dithering adds ~2ms over raw greyscale |
| Delta + LZ4 compress | Zig | <2ms | ~0.5ms | XOR + LZ4 block compression |
| TCP transport | Swift | <3ms | ~2ms | USB-C with `TCP_NODELAY`, typical <2ms |
| LZ4 decompress + apply | Zig (JNI) | <3ms | 5.2ms (NEON) | Zig's SIMD should match or beat ARM NEON C |
| **Pipeline total** | | **<12ms** | **10.5ms** | **Comparable to Daylight Mirror's LCD pipeline** |
| E-ink refresh (DW) | Boox SDK | ~200ms | N/A (LCD target) | Display hardware limit, not software |
| E-ink refresh (GU/GC) | Boox SDK | ~600ms | N/A (LCD target) | Display hardware limit, not software |
| **End-to-end (DW)** | | **~212ms** | N/A | **Pipeline is <6% of total latency** |
| **End-to-end (GU/GC)** | | **~612ms** | N/A | **Pipeline is <2% of total latency** |

### 9.2 Memory Budget

| Buffer | Size | Count | Total |
|--------|------|-------|-------|
| BGRA capture frame (1240x930) | 4.6 MB | 1 | 4.6 MB |
| Greyscale processed frame | 1.15 MB | 2 (double buffer) | 2.3 MB |
| Color processed frame (16-bit) | 2.3 MB | 2 (double buffer) | 4.6 MB |
| LZ4 compression output | 1.15 MB (worst case) | 1 | 1.15 MB |
| **Total pipeline memory** | | | **~12.65 MB** |

Memory is pre-allocated at startup. No allocations occur during the frame processing hot path.

### 9.3 Bandwidth Budget

For a 1240x930 display (Boox Note Air 3 C native resolution):

| Scenario | Raw frame | After delta | After LZ4 | Reduction |
|----------|-----------|-------------|------------|-----------|
| Static screen | 1.15 MB | 0 bytes | 0 bytes | 100% |
| Cursor blink | 1.15 MB | ~400 bytes | ~200 bytes | 99.98% |
| Line of text typed | 1.15 MB | ~24 KB | ~4 KB | 99.65% |
| Window scroll | 1.15 MB | ~800 KB | ~200 KB | 82.6% |
| Full screen change | 1.15 MB | 1.15 MB | ~300 KB | 73.9% (keyframe) |

USB 2.0 over ADB provides ~40 MB/s throughput. Even a full keyframe at 300 KB transfers in <10ms. Bandwidth is never the bottleneck.

---

## 10. Security and Permissions

### 10.1 macOS Permissions

- **Screen Recording** (required): For `ScreenCaptureKit` frame access. Prompted on first launch via `CGRequestScreenCaptureAccess()`.
- **Accessibility** (required): For `CGEvent` tablet input injection. Prompted via `AXIsProcessTrustedWithOptions()`.
- **No network access**: All communication is over USB via ADB. No internet connection required or requested.

### 10.2 Android Permissions

- **USB debugging must be enabled**: Required for ADB tunnel. The app itself needs no special Android permissions -- it communicates over a localhost TCP socket.
- **No root required**: `EpdController` and Wacom digitizer APIs are available to standard apps on Boox devices.

### 10.3 Private API Usage

The virtual display functionality uses Apple's private `CGVirtualDisplay` API accessed via `dlsym`. This is the same approach used by Daylight Mirror and SuperMirror. Risks:

- Could break on macOS updates (mitigated by testing on beta releases)
- Not eligible for Mac App Store distribution (the app will be distributed as a DMG)
- The `dlsym` approach provides a clean failure path -- if the symbol is not found, the app reports an incompatibility error rather than crashing

---

## 11. Testing Strategy

### 11.1 Zig Core (Unit Tests)

Every pipeline stage and delta encoder function has dedicated tests in `zig-core/tests/`:

- **Pipeline**: Synthetic pixel buffers (all-black, all-white, gradient, checkerboard). Verify greyscale coefficients match BT.709. Verify dithering output has correct shade count. Verify color quantization stays within Kaleido 3 gamut.
- **Delta**: Roundtrip encode-decode produces identical output. Identical frames produce zero-length delta. Single-pixel change produces minimal delta. Random frame pairs for fuzz testing.
- **FFI**: Verify that calling `export` functions from C produces correct results (tested via a C test harness compiled by `build.zig`).
- **Performance**: Benchmark tests assert that pipeline processing stays under 3ms for 1240x930 frames.

### 11.2 Integration Tests

- **Loopback test**: Mac-side captures, processes, encodes, sends over a localhost socket, receives, decodes, applies, and compares with original. Verifies the full pipeline without hardware.
- **Protocol test**: Verify header parsing, flag handling, sequence numbering, and ACK processing with a mock TCP connection.
- **Reconnection test**: Simulate transport drops and verify the system recovers (keyframe resent, state consistent).

### 11.3 On-Device Tests

- **Refresh mode selection**: Verify the correct BSR mode is chosen for various dirty percentages on actual Boox hardware.
- **Ghost measurement**: Capture photos of the e-ink display after extended use and measure ghosting levels to tune the ghost-clear interval.
- **Input latency**: Measure end-to-end stylus-to-cursor latency with a high-speed camera.

---

## 12. Glossary

| Term | Definition |
|------|-----------|
| **BSR** | Boox Screen Refresh -- collective name for Boox's e-ink refresh mode APIs |
| **DW** | Direct Waveform -- fastest e-ink refresh (~200ms), used for small incremental updates |
| **GU** | Grey Update -- moderate e-ink refresh (~600ms), preserves full greyscale range |
| **GC** | Global Clear -- slowest e-ink refresh (~600ms with flash), eliminates all ghosting |
| **Kaleido 3** | E Ink's color filter array technology used in the Boox Note Air 3 C. Overlays RGB filters on a greyscale e-ink matrix. Supports 4096 colors at 150ppi. |
| **Atkinson dithering** | Error-diffusion dithering algorithm that spreads only 3/4 of the quantization error. Produces sharper output than Floyd-Steinberg, better suited for text-heavy desktop content. |
| **Ghosting** | Faint residual image from previous content on e-ink displays, caused by incomplete pixel state transitions. Cleared by GC refresh. |
| **CompositorPacer** | Technique from Daylight Mirror: a tiny window alternates colors to force macOS compositor redraws at full refresh rate on virtual displays. |
| **ADB reverse tunnel** | Android Debug Bridge feature that maps a TCP port on the Android device to the host machine, enabling localhost connections to traverse USB. |
| **LZ4** | Fast lossless compression algorithm optimized for speed over ratio. Decompression is memory-bandwidth-bound, making it ideal for real-time frame data. |
