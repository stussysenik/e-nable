# e-nable — Project Instructions

## Overview

e-nable mirrors a Mac screen to a Boox Note Air 3 C e-ink tablet over USB-C. Native pipeline: Swift (macOS) + Zig (image processing) + Kotlin (Android).

## Architecture

- `zig-core/` — Shared image pipeline + delta encoding (compiles for macOS + Android)
- `macos/` — Swift app: screen capture, transport, input injection, menu bar
- `android/` — Kotlin APK: renderer, input capture, connection manager
- `openspec/` — Specifications and change proposals

## Code Standards

- **SRP** — every file does one thing
- **Educational comments** — explain WHY, not just WHAT. Teach e-ink, ADB, image processing
- **Modular** — clear interfaces between modules, testable in isolation
- **LOC-first** — read actual code before changing it, reference specific file:line

## Git Workflow

- Frequent commits with descriptive messages
- Git tags at every milestone (v0.1.0, v0.2.0, etc.)
- Feature branches per module

## Testing

- Test-first: write test → implement → verify
- Every Zig function gets unit tests + edge cases
- Integration tests at module boundaries
- Benchmark tests for performance budgets

## Build

```bash
make all          # Build everything
zig build test    # Zig tests (from zig-core/)
swift test        # Swift tests
./gradlew test    # Android tests (from android/)
```

## OpenSpec

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals
- Introduces new capabilities, breaking changes, architecture shifts
- Sounds ambiguous and you need the authoritative spec before coding
