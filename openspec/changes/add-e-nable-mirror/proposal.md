## Why

E-ink displays offer calm, paper-like computing — no blue light, no PWM flicker, no eye strain. No open-source solution exists that's optimized for the Boox Note Air 3 C's Kaleido 3 color e-ink panel. SuperMirror ($29, closed-source) targets the Daylight DC-1 reflective LCD, not real e-ink. Real e-ink needs dithering, refresh mode management, and ghost mitigation that LCD mirrors don't provide.

## What Changes

- **NEW**: Native macOS screen capture via private CGDisplayStream API with virtual display at Boox-native resolutions
- **NEW**: Zig image pipeline — BT.709 greyscale conversion, contrast LUT, Laplacian sharpening, Atkinson dithering (16-shade), octree color quantization (4096 colors for Kaleido 3)
- **NEW**: XOR delta encoding with LZ4 compression — only send changed screen regions (~60x bandwidth reduction)
- **NEW**: ADB socket tunnel transport with length-prefixed binary protocol, TCP_NODELAY, auto-reconnection
- **NEW**: Android renderer using Boox EpdController API — BSR refresh modes (GC/GU/DW), partial refresh, periodic ghost clearing
- **NEW**: Bidirectional stylus passthrough — Wacom EMR capture (4096 pressure levels, tilt) on Boox → CGEvent tablet injection on Mac
- **NEW**: macOS menu bar app + CLI (`e-nable start/stop/status/config`) with dual-interface IPC via Unix domain socket
- **NEW**: Dual render modes — B&W (300ppi, Atkinson dithered) and Color (150ppi, octree quantized), user-toggleable at runtime

## Capabilities

### New Capabilities
- `screen-capture`: Virtual display creation at Boox-native resolutions, frame acquisition via CGDisplayStream, resolution presets, adaptive frame rate
- `image-pipeline`: Greyscale conversion, contrast LUT, sharpening, Atkinson dithering, octree color quantization, B&W/Color mode toggle
- `delta-encoding`: XOR frame differencing, dirty region detection, LZ4 compression, full-frame fallback
- `transport`: ADB reverse tunnel setup, length-prefixed binary protocol, bidirectional multiplexing, auto-reconnection, backpressure
- `eink-renderer`: Delta patch application, EpdController BSR mode selection, partial refresh, ghost mitigation scheduling
- `stylus-input`: Wacom EMR capture (pressure/tilt/position), touch capture, serialization, Mac-side CGEvent tablet injection
- `app-shell`: macOS menu bar app, CLI interface, settings management, keyboard shortcuts, Unix domain socket IPC

### Modified Capabilities
(none — greenfield project)

## Impact

- **macOS**: Requires macOS 14+ (Sonoma), Apple Silicon. Uses private APIs (CGVirtualDisplay, CGDisplayStream via dlsym). Needs Screen Recording + Accessibility permissions.
- **Android**: Requires Boox device with Android 12+, USB debugging enabled. Depends on Onyx SDK (onyxsdk-device:1.1.11, onyxsdk-pen:1.2.1).
- **Build toolchain**: Zig compiler (0.13+), Swift 5.9+, Android SDK 34, NDK 26+, ADB platform tools.
- **Dependencies**: LZ4 (Zig port or C binding), Boox Maven repo (repo.boox.com).
