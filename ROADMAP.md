# Roadmap

Where e-nable is going. This is a living document &mdash; priorities shift as we learn from real usage on actual e-ink hardware.

## Philosophy

**Calm computing.** Every decision optimizes for a distraction-free, paper-like experience. If a feature adds visual noise or complexity without measurably improving the e-ink experience, it doesn't ship.

**Browser-first, native-optional.** The primary receiver is the Boox's built-in browser. The native Android app is an optimization layer for users who want BSR refresh control and lower latency &mdash; not a requirement.

**One codebase, many displays.** The Zig core and Elixir server are device-agnostic. Adding support for a new e-ink tablet should be a configuration change, not a rewrite.

---

## Near Term (v0.4 - v0.5)

### v0.4.0 &mdash; Stable Mirror
- [ ] Wire Zig delta encoding into Swift capture (XOR + RLE, ~60x bandwidth reduction)
- [ ] Frame rate adaptation (only send when screen content changes)
- [ ] Reduce browser bandwidth from ~5MB/s to ~100KB/s
- [ ] Connection resilience (auto-reconnect on WiFi drop)
- [ ] mDNS/Bonjour discovery (no need to type IP address)

### v0.5.0 &mdash; LiveView Dashboard
- [ ] Phoenix LiveView settings panel at `/`
- [ ] Resolution picker, mode toggle (B&W/color), brightness/contrast sliders
- [ ] Connection status, FPS graph, bandwidth monitor
- [ ] QR code for easy Boox connection

## Medium Term (v0.6 - v0.8)

### v0.6.0 &mdash; Stylus Input
- [ ] Touch events from browser relay back to Mac
- [ ] Wacom pressure/tilt via Pointer Events API
- [ ] CGEvent injection on Mac (stylus becomes a tablet input)
- [ ] Latency < 50ms touch-to-cursor

### v0.7.0 &mdash; Virtual Display
- [ ] CGVirtualDisplay integration (bypass SIP restrictions)
- [ ] Dedicated 4:3 or 3:4 display for the Boox
- [ ] macOS treats Boox as a real second monitor
- [ ] Clamshell mode (close MacBook, use Boox as primary)

### v0.8.0 &mdash; Color Mode
- [ ] Octree color quantization for Kaleido 3 (4096 colors)
- [ ] Runtime B&W ↔ Color toggle
- [ ] Color-aware delta encoding
- [ ] Optimized for Boox's 150ppi color layer

## Long Term (v0.9 - v1.0)

### v0.9.0 &mdash; Native Android App
- [ ] Kotlin APK with Boox EpdController BSR modes
- [ ] DW mode for text (200ms refresh, zero ghosting)
- [ ] GC mode for ghost clearing (periodic full refresh)
- [ ] Pre-built APK via GitHub Actions CI
- [ ] One-tap install from GitHub Releases

### v1.0.0 &mdash; Release
- [ ] Homebrew formula (`brew install e-nable`)
- [ ] DMG installer for macOS
- [ ] Signed APK for Boox
- [ ] Comprehensive docs and setup guide
- [ ] Performance: full pipeline < 5ms, delta bandwidth < 50KB/s
- [ ] Support for: Boox Note Air 3 C, Boox Tab Ultra C, Boox Go 10.3

## Future Ideas

These are things we're thinking about but haven't committed to:

- **Multi-device** &mdash; mirror to multiple e-ink tablets simultaneously (Elixir handles this naturally)
- **Cloud relay** &mdash; mirror over the internet, not just local WiFi (Elixir + Fly.io)
- **Linux support** &mdash; replace ScreenCaptureKit with PipeWire/X11 capture
- **Annotation mode** &mdash; draw on the Boox, overlay appears on Mac (like a Wacom Cintiq)
- **App-specific mirroring** &mdash; mirror only one window, not the whole screen
- **E-ink optimized themes** &mdash; automatically switch Mac apps to high-contrast themes when mirroring
- **Dasung/Hisense support** &mdash; extend to other e-ink monitors and phones

---

*This roadmap reflects our current thinking. It's not a promise &mdash; it's a direction.*
