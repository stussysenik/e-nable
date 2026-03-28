## 1. Project Setup

- [ ] 1.1 Create `zig-core/` directory with `build.zig` supporting cross-compilation (aarch64-macos, aarch64-linux-android)
- [ ] 1.2 Create `macos/` Swift Package with `Package.swift` (platform macOS 14+, swift-tools 5.9)
- [ ] 1.3 Create `android/` Gradle project with NDK 26+, SDK 34, Boox Maven repo, JNI bridge stub
- [ ] 1.4 Wire up top-level `Makefile` to build all three targets
- [ ] 1.5 Verify cross-compilation: `zig build` produces both .dylib and .so

## 2. Zig Core — Image Pipeline (REQ-IP-001 through IP-006)

- [ ] 2.1 Implement `pipeline.zig`: BT.709 greyscale conversion using SIMD vectors — test with all-white, all-black, pure R/G/B, natural content
- [ ] 2.2 Implement `pipeline.zig`: contrast LUT with configurable gamma — test identity (gamma=1.0), default (1.2), extremes (0.5, 3.0)
- [ ] 2.3 Implement `pipeline.zig`: Laplacian unsharp mask sharpening — test disabled (0.0), default (1.5), max (3.0), single-pixel features
- [ ] 2.4 Implement `dither.zig`: Atkinson dithering (16-level) — test smooth gradient, text content, solid color, checkerboard
- [ ] 2.5 Implement `color.zig`: octree color quantization (4096 colors) — test photo content, solid colors, near-boundary colors
- [ ] 2.6 Implement `ffi.zig`: C ABI exports for all pipeline functions — verify callable from C test harness
- [ ] 2.7 Benchmark: verify greyscale+dither processes 1240×930 frame in <3ms
- [ ] 2.8 Tag `v0.1.0`

## 3. Zig Core — Delta Encoding (REQ-DE-001 through DE-005)

- [ ] 3.1 Implement `delta.zig`: XOR frame differencing — test identical frames, single pixel, cursor blink, full change
- [ ] 3.2 Implement `delta.zig`: dirty region detection + rectangle packing — test single region, scattered, edge-touching, full-screen
- [ ] 3.3 Implement `delta.zig`: LZ4 compression integration — test typical delta (>60× reduction), empty, worst-case, roundtrip
- [ ] 3.4 Implement `delta.zig`: full-frame fallback when >60% dirty — test threshold crossing, forced keyframe
- [ ] 3.5 Property test: roundtrip integrity — random pixel buffers, encode→decode = original exactly
- [ ] 3.6 Benchmark: delta+compress for typical desktop content <2ms
- [ ] 3.7 Tag `v0.2.0`

## 4. macOS — Screen Capture (REQ-SC-001 through SC-005)

- [ ] 4.1 Implement `VirtualDisplay.swift`: CGVirtualDisplay creation via private API (dlsym) at Boox resolutions
- [ ] 4.2 Implement `FrameProducer.swift`: CGDisplayStream frame acquisition with cursor rendering
- [ ] 4.3 Implement resolution presets: cozy (800×600), comfortable (1024×768), balanced (1240×930), sharp (2480×1860)
- [ ] 4.4 Implement `CompositorPacer.swift`: 4×4px window toggle for 60Hz compositor forcing
- [ ] 4.5 Wire Swift→Zig FFI: bridging header for pipeline and delta C exports
- [ ] 4.6 Test: virtual display create/teardown, frame format verification, resolution switching
- [ ] 4.7 Tag `v0.3.0`

## 5. macOS — Transport Layer (REQ-TR-001 through TR-005)

- [ ] 5.1 Implement `ADBConnection.swift`: reverse tunnel setup, shell env loading, device detection
- [ ] 5.2 Implement `SocketTunnel.swift`: length-prefixed binary protocol (11-byte header, TCP_NODELAY)
- [ ] 5.3 Implement bidirectional multiplexing: frames Mac→Boox, input Boox→Mac, control messages both ways
- [ ] 5.4 Implement auto-reconnection: USB disconnect detection, exponential backoff, state restoration (resend keyframe + settings)
- [ ] 5.5 Implement backpressure: RTT tracking via ACK packets, frame dropping when client overwhelmed
- [ ] 5.6 Test: loopback protocol test, simulated disconnect/reconnect, backpressure under load
- [ ] 5.7 Tag `v0.4.0`

## 6. Android — Renderer (REQ-ER-001 through ER-005)

- [ ] 6.1 Create `ConnectionManager.kt`: ADB socket client, receive compressed frames
- [ ] 6.2 Create JNI bridge: `zig_bridge.c` thin wrapper calling Zig delta decode + pipeline exports
- [ ] 6.3 Implement `RendererService.kt`: apply delta patches to screen buffer via SurfaceView
- [ ] 6.4 Integrate Boox SDK: `EpdController.invalidate()` with BSR mode selection (DW <10%, GU 10-60%, GC >60%)
- [ ] 6.5 Implement partial refresh: apply only dirty regions, not full screen
- [ ] 6.6 Implement ghost mitigation: periodic GC full refresh (configurable interval, default 30 frames)
- [ ] 6.7 Implement dual render path: B&W at 300ppi native, Color at 150ppi native
- [ ] 6.8 Test: BSR mode selection logic, delta application, refresh scheduling
- [ ] 6.9 Tag `v0.5.0`

## 7. End-to-End Integration (first pass)

- [ ] 7.1 Wire capture→pipeline→delta→transport→renderer full pipeline
- [ ] 7.2 Test with simulated frames: synthetic content through entire chain
- [ ] 7.3 Measure full pipeline latency, verify <12ms (excluding e-ink refresh)
- [ ] 7.4 Test connection lifecycle: connect, mirror, disconnect, reconnect with state restoration
- [ ] 7.5 Stress test: rapid frame changes, connection drops, mode switches
- [ ] 7.6 Tag `v0.6.0`

## 8. Stylus Input (REQ-SI-001 through SI-004)

- [ ] 8.1 Implement `InputCapture.kt`: Wacom EMR capture (pressure, tilt, x/y) via MotionEvent.getToolType()
- [ ] 8.2 Implement `InputCapture.kt`: capacitive touch capture (tap, drag, scroll, pinch)
- [ ] 8.3 Implement event serialization: 20-byte binary packets (type, x, y, pressure, tilt, flags, timestamp)
- [ ] 8.4 Implement `TabletInjector.swift`: CGEvent tablet event injection via IOKit
- [ ] 8.5 Test: serialization roundtrip, pressure/tilt accuracy, stylus ↔ touch discrimination
- [ ] 8.6 Test on device: verify stylus input on Boox controls Mac cursor with pressure
- [ ] 8.7 Tag `v0.7.0`

## 9. Color Mode (REQ-IP-005, IP-006, ER-005)

- [ ] 9.1 Wire color quantization pipeline: BGRA → octree → 4096-color output
- [ ] 9.2 Implement runtime B&W↔Color toggle: mode flag in protocol header, no reconnect needed
- [ ] 9.3 Implement color-aware delta encoding: handle color frame differencing
- [ ] 9.4 Test mode switch during active mirroring, color accuracy, delta efficiency in color mode
- [ ] 9.5 Tag `v0.8.0`

## 10. App Shell (REQ-AS-001 through AS-005)

- [ ] 10.1 Implement `MenuBarApp.swift`: SwiftUI menu bar with connection badge (grey/yellow/green/red)
- [ ] 10.2 Implement `CLI.swift`: `e-nable start/stop/status/config` commands
- [ ] 10.3 Implement Unix domain socket IPC: shared socket at /tmp/e-nable.sock, CLI controls GUI
- [ ] 10.4 Implement `Settings.swift`: persist resolution, mode, brightness, warmth, sharpening, ghost interval
- [ ] 10.5 Implement keyboard shortcuts: Ctrl+F1/F2 brightness, Ctrl+F8 toggle mirror, Ctrl+F11/F12 warmth
- [ ] 10.6 Setup wizard: permissions (Screen Recording + Accessibility), device detection, first-run flow
- [ ] 10.7 Test: CLI parsing, settings persistence, IPC between CLI and GUI
- [ ] 10.8 Tag `v0.9.0`

## 11. Release

- [ ] 11.1 Full test suite passes: `zig build test`, `swift test`, `./gradlew test`
- [ ] 11.2 End-to-end on-device validation: Boox Note Air 3 C connected, mirroring works
- [ ] 11.3 Build DMG installer (codesigned)
- [ ] 11.4 Build signed APK
- [ ] 11.5 Write setup guide in README
- [ ] 11.6 OpenSpec validate passes: `openspec validate add-e-nable-mirror --strict --no-interactive`
- [ ] 11.7 Tag `v1.0.0`
