# Progress

A transparent log of what's built, what works, and what's honest-to-god broken.

---

## v0.3.0 &mdash; "It's Alive" (current)

**Date:** 2026-03-28

**What works:**
- Mac screen capture at 5 FPS via ScreenCaptureKit
- BT.709 greyscale conversion streaming to Elixir server
- Elixir Phoenix server relaying frames via WebSocket
- Browser at `/mirror.html` renders greyscale frames on canvas
- Visible on any device on the same WiFi network (tested: iPhone, Mac browser)

**What's rough:**
- Every frame is a full keyframe (~1.1MB) &mdash; no delta encoding wired yet, so bandwidth is ~5.5MB/s
- Image quality is raw greyscale without Zig dithering (Swift does a temporary BT.709 conversion)
- No frame rate adaptation &mdash; sends 5 FPS even when screen is static
- Browser reconnection works but can be slow
- No settings UI &mdash; everything is hardcoded

**What's broken:**
- Virtual display creation fails on Mac Studio (SIP blocks CGVirtualDisplay private API)
- E-ink specific refresh optimizations not implemented in browser
- Stylus/touch input not wired end-to-end

**Numbers:**

| Metric | Value |
|--------|-------|
| Source files | 68 |
| Lines of code | 15,708 |
| Zig unit tests | 113 passing |
| Elixir tests | 5 passing |
| Zig pipeline latency | 2.23ms total |
| Greyscale conversion | 0.12ms |
| Atkinson dithering | 1.05ms (was 10ms before SIMD optimization) |
| XOR delta | 0.05ms |
| Capture frame rate | 5 FPS |
| Frame size (keyframe) | 1,153,200 bytes (1240x930 greyscale) |
| Git commits | 15 |
| Git tags | 4 (v0.0.0 → v0.3.0) |

---

## v0.2.0 &mdash; "Three Platforms"

**Date:** 2026-03-28

All three platform layers built and compiling:
- Zig core: image pipeline + delta encoding with 113 tests
- Swift macOS: screen capture, transport, ADB bridge, input injection
- Kotlin Android: renderer, Boox SDK integration, input capture

Code review found 10 issues in Zig core, 4 critical fixed immediately.
Atkinson dithering optimized from 10ms to 1.05ms (9x faster).

---

## v0.1.0 &mdash; "Zig Core"

**Date:** 2026-03-28

Complete Zig image processing library:
- `pipeline.zig` &mdash; BT.709 greyscale, contrast LUT, Laplacian sharpening
- `dither.zig` &mdash; Atkinson error diffusion (16-level quantization)
- `delta.zig` &mdash; XOR differencing, dirty region detection, RLE compression
- `color.zig` &mdash; 4096-color channel quantization stub
- `ffi.zig` &mdash; C ABI exports for Swift FFI and JNI
- `bench.zig` &mdash; performance benchmarks

All 113 tests passing. All benchmarks under budget.

---

## v0.0.0 &mdash; "Scaffold"

**Date:** 2026-03-28

Project bootstrap: git init, README, CLAUDE.md, Makefile, LICENSE (MIT).
OpenSpec initialized with 35 requirements and 111 scenarios across 7 capability specs.

---

## Architecture Decisions

Decisions made during development and why:

| Decision | Why |
|----------|-----|
| **Zig for image pipeline** | Zero GPU, SIMD-friendly, single codebase compiles for macOS + Android via C ABI |
| **Elixir/Phoenix for server** | Best-in-class WebSocket, BEAM for concurrent viewers, LiveView for future dashboard |
| **Browser-first receiver** | Zero install on Boox. Opens in 5 seconds vs 30 minutes to sideload an APK |
| **Atkinson over Floyd-Steinberg** | 30% faster, higher contrast, better for e-ink text rendering |
| **Raw WebSocket over Phoenix Channels** | Binary frame data without JSON/base64 encoding overhead |
| **Swift ScreenCaptureKit** | Only stable macOS screen capture API. Private CGDisplayStream explored but blocked by SIP |
| **XOR delta + RLE** | Simple, fast, 60x compression on typical desktop content. LZ4 planned for v0.4 |

## Lessons Learned

Things we got wrong and fixed:

1. **CGVirtualDisplay private API doesn't work on Mac Studio** &mdash; SIP blocks dlsym. Pivoted to capturing main display directly.
2. **Phoenix `socket` macro only works with Phoenix.Socket** &mdash; raw WebSocket needs `WebSockAdapter.upgrade/3` via a Plug.
3. **Metadata key names must match across boundaries** &mdash; FrameIngress used `:seq`, MirrorWs read `:sequence`. Always grep for key usage across files.
4. **Frames without delta encoding must all be keyframes** &mdash; sending full frames as "delta" causes XOR to produce garbage noise.
5. **Dithering is the performance bottleneck, not the pipeline** &mdash; naive Atkinson was 10ms. Comptime LUT + interior/border split + early-out brought it to 1.05ms.
