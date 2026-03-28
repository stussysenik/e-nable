# e-nable

**Your Mac, on e-ink.** Mirror your Mac screen to a Boox Note Air 3 C (or other e-ink tablets) over USB-C with zero GPU usage, sub-10ms latency, and a pixel pipeline built for paper.

## What is this?

e-nable is a native macOS app that turns your Boox e-ink tablet into an external display. It captures your Mac screen, processes it through an e-ink-optimized image pipeline, and streams it to the tablet over USB — with stylus input flowing back.

### Features

- **Dual render modes** — B&W (300ppi, 16-shade dithering) or Color (150ppi, 4096-color Kaleido 3)
- **Delta encoding** — only sends changed screen regions, perfect for e-ink's slow refresh
- **Stylus passthrough** — use the Boox's Wacom pen as a tablet input on your Mac
- **Zero GPU** — all image processing in Zig, runs on CPU with SIMD
- **Sub-10ms latency** — native pipeline, no video codecs, no compression artifacts

### Architecture

```
Mac (Swift + Zig)          USB-C / ADB          Boox (Kotlin + Zig)
┌──────────────────┐                          ┌──────────────────┐
│ ScreenCaptureKit │──▶ Zig Pipeline ──▶ ADB ──▶ Zig Renderer   │
│ Virtual Display   │     (greyscale,          │ (BSR refresh,    │
│                   │      dither, delta)       │  partial update) │
│ Input Injector  ◀─────── ADB ◀────────────── Input Capture    │
│ (CGEvent)         │                          │ (Wacom digitizer)│
└──────────────────┘                          └──────────────────┘
```

### Tech Stack

| Layer | Language | Purpose |
|-------|----------|---------|
| Screen capture | Swift | ScreenCaptureKit, virtual display |
| Image pipeline | Zig | Greyscale, LUT, sharpen, dither, color quant |
| Delta encoding | Zig | Frame diff, region packing, RLE |
| Transport | Swift | ADB socket tunnel, multiplexing |
| Renderer | Kotlin + Zig (JNI) | BSR modes, partial refresh |
| Input | Kotlin → Swift | Wacom capture → CGEvent injection |
| App | Swift | Menu bar + CLI |

## Quick Start

```bash
# Build everything
make all

# Connect Boox via USB-C, then:
e-nable start

# CLI controls
e-nable status
e-nable config --mode bw --resolution sharp
e-nable stop
```

## Development

```bash
# Run Zig core tests
cd zig-core && zig build test

# Run Swift tests
swift test

# Run Android tests
cd android && ./gradlew test
```

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Inspired by [Daylight Mirror](https://github.com/welfvh/daylight-mirror) by Welf von Horen and [SuperMirror](https://supermirror.app).
