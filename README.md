<p align="center">
  <h1 align="center">e-nable</h1>
  <p align="center"><strong>Your Mac, on e-ink.</strong></p>
  <p align="center">
    Mirror your Mac screen to a Boox e-ink tablet over WiFi.<br/>
    No apps to install. No cables. Just open a URL.
  </p>
  <p align="center">
    <a href="#quick-start">Quick Start</a> &bull;
    <a href="#how-it-works">How It Works</a> &bull;
    <a href="ROADMAP.md">Roadmap</a> &bull;
    <a href="PROGRESS.md">Progress</a>
  </p>
</p>

---

## Why

E-ink displays are calm. No blue light. No PWM flicker. No eye strain. They're paper that updates.

We wanted to use a Boox Note Air 3 C as a secondary Mac display for writing, reading, and focused work. The commercial options are either expensive (SuperMirror, $29, closed-source) or built for different hardware (Daylight DC-1's reflective LCD, not real e-ink).

So we built **e-nable** &mdash; an open-source screen mirror optimized for real e-ink panels, with an Elixir server at the center and zero install required on the tablet side.

## What It Does

```
Mac Screen  -->  Swift Capture  -->  Zig Pipeline  -->  Elixir Server  -->  Browser on Boox
                                     (greyscale,        (WebSocket)         (canvas render)
                                      dither,
                                      compress)
```

- Captures your Mac screen via ScreenCaptureKit
- Converts to greyscale using BT.709 luma (0.12ms per frame)
- Applies Atkinson dithering for 16-shade e-ink (1.05ms per frame)
- Streams via Elixir Phoenix over WebSocket
- Renders on the Boox's built-in browser &mdash; **nothing to install on the tablet**

## Quick Start

**Prerequisites:** macOS 14+, Elixir 1.17+ (`brew install elixir`)

```bash
# Clone
git clone https://github.com/stussysenik/e-nable.git
cd e-nable

# One-time setup
make setup

# Start mirroring
make start
```

Then on your Boox (or any device on the same WiFi):

```
Open browser --> http://your-mac-ip:4000/mirror.html
```

Your Mac screen appears on e-ink. Done.

## How It Works

### Architecture

| Layer | Language | What it does |
|-------|----------|-------------|
| **Screen Capture** | Swift | ScreenCaptureKit grabs your Mac display at 5 FPS |
| **Image Pipeline** | Zig | BT.709 greyscale, contrast LUT, Atkinson dithering, delta encoding |
| **Streaming Server** | Elixir/Phoenix | Receives frames via TCP, broadcasts via WebSocket to browsers |
| **Browser Renderer** | JavaScript | Canvas-based rendering with XOR delta support, e-ink optimizations |
| **Android App** | Kotlin | Native Boox renderer with EpdController BSR modes (optional, for power users) |

### The Zig Core

The image pipeline is written in Zig for maximum performance with zero GPU usage:

```
Greyscale (0.12ms) --> Contrast LUT --> Sharpening --> Atkinson Dither (1.05ms) --> Delta Encode (0.05ms)
```

113 unit tests. Benchmarked on Apple Silicon. The full pipeline processes a 1240x930 frame in **2.23ms** &mdash; 5x under our 12ms budget.

### Why Elixir?

Phoenix Channels give us real-time WebSocket broadcasting with zero configuration. The BEAM VM handles concurrent viewers effortlessly. And for the long game &mdash; multi-device support, cloud relay, LiveView dashboard &mdash; Elixir scales beautifully.

### Why Browser Instead of a Native App?

Zero friction. The Boox has a built-in Chromium browser. Opening a URL takes 5 seconds. Building, signing, and sideloading an APK takes 30 minutes and requires Android development tools. We chose the path that lets you see your screen on e-ink in under a minute.

## Project Structure

```
e-nable/
  zig-core/         Shared image pipeline (Zig) — greyscale, dither, delta, FFI
  macos/            Screen capture + streaming client (Swift)
  server/           Elixir Phoenix server — frame relay + WebSocket
  android/          Native Boox renderer (Kotlin) — optional, for power users
  openspec/         Formal specifications (35 requirements, 111 scenarios)
```

## Current Status

**v0.3.0** &mdash; End-to-end mirroring works. Mac screen visible in browser over WiFi.

See [PROGRESS.md](PROGRESS.md) for detailed status and [ROADMAP.md](ROADMAP.md) for what's next.

| What | Status |
|------|--------|
| Zig image pipeline | 113 tests passing, all benchmarks under budget |
| Swift screen capture | Working, 5 FPS, greyscale streaming |
| Elixir server | WebSocket broadcasting, frame relay |
| Browser renderer | Canvas rendering, keyframe display |
| Delta encoding | Zig core done, not yet wired to Swift |
| Stylus input | Code written, not yet integrated |
| Color mode | Zig stub, full octree in roadmap |

## Development

```bash
# Run Zig tests
cd zig-core && zig build test

# Run Elixir tests
cd server && mix test

# Build Swift
cd macos && swift build

# Run benchmarks
cd zig-core && zig build bench
```

## Inspired By

- [Daylight Mirror](https://github.com/welfvh/daylight-mirror) by Welf von Horen &mdash; the open-source Mac-to-DC1 mirror that started it all
- [SuperMirror](https://supermirror.app) &mdash; the commercial evolution
- [KOReader](https://github.com/koreader/koreader) &mdash; for Boox SDK patterns and EPD controller reference

## License

MIT &mdash; see [LICENSE](LICENSE).

---

<p align="center">
  <em>Built with Zig, Swift, Elixir, and Kotlin.<br/>
  Designed for paper. Optimized for calm.</em>
</p>
