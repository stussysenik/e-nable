// --------------------------------------------------------------------------
// main.swift - Minimal CLI entry point for the EnableCapture pipeline
//
// This executable is for development testing only. It:
//   1. Creates a virtual display at a chosen Boox preset resolution
//   2. Starts the compositor pacer
//   3. Captures a handful of frames via ScreenCaptureKit
//   4. Reports frame stats and tears everything down
//
// Usage:
//   swift run EnableCLI [preset]
//
//   preset: tab-ultra-c-pro | note-air3-c | go-10.3 | tab-mini-c
//           (default: tab-ultra-c-pro)
//
// Learning note (Swift concurrency + main.swift):
//   Top-level code in main.swift can use `await` directly starting in
//   Swift 5.9. We wrap our async pipeline in a helper and call it.
// --------------------------------------------------------------------------

import CoreMedia
import EnableCapture
import Foundation

// MARK: - Entry Point

/// Parse the optional preset argument from the command line.
func parsePreset() -> ResolutionPreset {
    let args = CommandLine.arguments
    guard args.count > 1 else { return .tabUltraCPro }

    let raw = args[1]
    if let preset = ResolutionPreset(rawValue: raw) {
        return preset
    }

    // Friendly error message listing valid presets.
    print("Unknown preset: '\(raw)'")
    print("Valid presets:")
    for p in ResolutionPreset.allCases {
        print("  \(p.rawValue)  ->  \(p.displayName)")
    }
    exit(1)
}

/// Main async pipeline.
func runCapturePipeline() async throws {
    let preset = parsePreset()
    print("[EnableCLI] Starting capture pipeline")
    print("[EnableCLI] Preset: \(preset.displayName)")
    print("[EnableCLI] Resolution: \(preset.width) x \(preset.height)")
    print()

    // -- Step 1: Virtual Display -----------------------------------------------
    print("[1/3] Creating virtual display...")
    let display: VirtualDisplay
    do {
        display = try VirtualDisplay(preset: preset)
    } catch {
        print("  FAILED: \(error.localizedDescription)")
        print("  Note: CGVirtualDisplay requires macOS 14+ and SIP may block dlsym.")
        throw error
    }
    print("  OK  Display ID: \(display.displayID)")
    print()

    // -- Step 2: Compositor Pacer -----------------------------------------------
    print("[2/3] Starting compositor pacer...")
    let pacer: CompositorPacer
    do {
        pacer = try CompositorPacer(displayID: display.displayID)
    } catch {
        display.teardown()
        print("  FAILED: \(error.localizedDescription)")
        throw error
    }
    print("  OK  4x4 px pacer window placed on virtual display")
    print()

    // -- Step 3: Frame Capture --------------------------------------------------
    print("[3/3] Capturing frames (5 seconds @ 2 fps)...")
    let producer: FrameProducer
    do {
        producer = try await FrameProducer(
            displayID: display.displayID,
            width: preset.width,
            height: preset.height,
            frameRate: 2
        )
    } catch {
        pacer.stop()
        display.teardown()
        print("  FAILED: \(error.localizedDescription)")
        throw error
    }

    try await producer.start()

    var frameCount = 0
    let deadline = Date().addingTimeInterval(5.0)

    for await frame in producer.frames {
        frameCount += 1
        let hasSurface = frame.surface != nil ? "yes" : "no"
        let ts = CMTimeGetSeconds(frame.timestamp)
        print("  Frame \(frameCount): surface=\(hasSurface), pts=\(String(format: "%.3f", ts))s")

        if Date() >= deadline {
            break
        }
    }

    // -- Cleanup ---------------------------------------------------------------
    await producer.stop()
    pacer.stop()
    display.teardown()

    print()
    print("[EnableCLI] Done. Captured \(frameCount) frames in ~5 seconds.")
    print("[EnableCLI] Pipeline: VirtualDisplay -> CompositorPacer -> FrameProducer -> OK")
}

// -- Run --------------------------------------------------------------------

// We need an NSApplication for the compositor pacer window to work,
// but we don't want a full app lifecycle. A simple async entry suffices.

do {
    try await runCapturePipeline()
} catch {
    print("\nFATAL: \(error.localizedDescription)")
    exit(1)
}
