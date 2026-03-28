// --------------------------------------------------------------------------
// main.swift - CLI entry point for the EnableCapture -> Elixir pipeline
//
// This executable wires the full capture-to-server pipeline:
//   1. Creates a virtual display at a chosen Boox preset resolution
//   2. Starts the compositor pacer
//   3. Captures frames via ScreenCaptureKit
//   4. Converts each frame to greyscale (BT.709)
//   5. Streams greyscale frames to the Elixir server over TCP
//   6. Reports connection status and FPS
//
// Usage:
//   swift run EnableCLI [preset] [--host HOST] [--port PORT] [--duration SECS]
//
//   preset:   tab-ultra-c-pro | note-air3-c | go-10.3 | tab-mini-c
//             (default: tab-ultra-c-pro)
//   --host:   Elixir server host (default: 127.0.0.1)
//   --port:   Elixir server TCP port (default: 9999)
//   --duration: Capture duration in seconds (default: 30)
//
// Learning note (Swift concurrency + main.swift):
//   Top-level code in main.swift can use `await` directly starting in
//   Swift 5.9. We wrap our async pipeline in a helper and call it.
//
// Learning note (BT.709 greyscale conversion):
//   E-ink displays are greyscale, so we convert BGRA frames before sending.
//   BT.709 luma coefficients (R=0.2126, G=0.7152, B=0.0722) are the standard
//   for HDTV and modern displays. We use integer approximation:
//     Y = (R*54 + G*183 + B*19 + 128) >> 8
//   where 54/256≈0.211, 183/256≈0.715, 19/256≈0.074 — close to BT.709.
// --------------------------------------------------------------------------

import CoreMedia
import EnableCapture
import Foundation
import IOSurface

// MARK: - CLI Argument Parsing

/// Parsed CLI options.
struct CLIOptions {
    var preset: ResolutionPreset = .tabUltraCPro
    var host: String = "127.0.0.1"
    var port: UInt16 = 9999
    var duration: Double = 30.0
}

/// Parse command-line arguments into structured options.
///
/// Supports positional preset argument and optional --host, --port, --duration flags.
func parseArguments() -> CLIOptions {
    var options = CLIOptions()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--host":
            i += 1
            guard i < args.count else {
                print("Error: --host requires a value")
                exit(1)
            }
            options.host = args[i]

        case "--port":
            i += 1
            guard i < args.count, let port = UInt16(args[i]) else {
                print("Error: --port requires a valid port number")
                exit(1)
            }
            options.port = port

        case "--duration":
            i += 1
            guard i < args.count, let secs = Double(args[i]) else {
                print("Error: --duration requires a number of seconds")
                exit(1)
            }
            options.duration = secs

        default:
            // Positional argument: preset name
            if let preset = ResolutionPreset(rawValue: args[i]) {
                options.preset = preset
            } else {
                print("Unknown argument: '\(args[i])'")
                print("Valid presets:")
                for p in ResolutionPreset.allCases {
                    print("  \(p.rawValue)  ->  \(p.displayName)")
                }
                print("\nFlags: --host HOST  --port PORT  --duration SECS")
                exit(1)
            }
        }
        i += 1
    }

    return options
}

// MARK: - Greyscale Conversion

/// Convert a BGRA pixel buffer to single-channel greyscale using BT.709 luma.
///
/// This is a temporary pure-Swift implementation used until the Zig FFI
/// dithering core is wired in. The Zig version will handle both greyscale
/// conversion and Floyd-Steinberg dithering in a single optimized pass.
///
/// - Parameters:
///   - bgra: Raw BGRA pixel data (4 bytes per pixel).
///   - width: Image width in pixels.
///   - height: Image height in pixels.
/// - Returns: Single-channel greyscale data (1 byte per pixel, width*height bytes).
func toGreyscale(bgra: Data, width: Int, height: Int) -> Data {
    let pixelCount = width * height
    // Use [UInt8] for the conversion loop — avoids nested Data.withUnsafeBytes
    // closures that cause the Swift type-checker to bail out.
    let bgraBytes = [UInt8](bgra)
    var greyBytes = [UInt8](repeating: 0, count: pixelCount)

    for i in 0..<pixelCount {
        let offset = i * 4
        let b = Int(bgraBytes[offset])
        let g = Int(bgraBytes[offset + 1])
        let r = Int(bgraBytes[offset + 2])
        // BT.709 integer approximation: 54/256≈0.211, 183/256≈0.715, 19/256≈0.074
        greyBytes[i] = UInt8((r * 54 + g * 183 + b * 19 + 128) >> 8)
    }

    return Data(greyBytes)
}

/// Extract BGRA pixel data from an IOSurface.
///
/// Learning note (IOSurface locking):
///   IOSurface.lock() with .readOnly ensures the GPU has finished writing
///   before we read. The lock/unlock pair is mandatory — reading without
///   locking can produce torn or corrupted frames. We copy the data out
///   immediately and unlock, minimizing the lock hold time.
///
/// - Parameters:
///   - surface: The IOSurface to read from.
///   - width: Expected width in pixels.
///   - height: Expected height in pixels.
/// - Returns: BGRA pixel data, or nil if the surface cannot be read.
func extractBGRA(from surface: IOSurface, width: Int, height: Int) -> Data? {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }

    let baseAddress = surface.baseAddress
    let bytesPerRow = surface.bytesPerRow
    let expectedBytesPerRow = width * 4

    // Copy row by row to handle stride padding.
    var data = Data(capacity: width * height * 4)
    for row in 0..<height {
        let rowStart = baseAddress + row * bytesPerRow
        data.append(Data(bytes: rowStart, count: expectedBytesPerRow))
    }

    return data
}

// MARK: - Main Pipeline

/// Main async pipeline: capture -> greyscale -> stream to Elixir.
func runStreamingPipeline() async throws {
    let options = parseArguments()
    let preset = options.preset

    print("╔══════════════════════════════════════════════════╗")
    print("║          e-nable capture -> server               ║")
    print("╚══════════════════════════════════════════════════╝")
    print()
    print("[EnableCLI] Preset:   \(preset.displayName)")
    print("[EnableCLI] Resolution: \(preset.width) x \(preset.height)")
    print("[EnableCLI] Server:   \(options.host):\(options.port)")
    print("[EnableCLI] Duration: \(Int(options.duration))s")
    print()

    // -- Step 1: Virtual Display -----------------------------------------------
    print("[1/5] Creating virtual display...")
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
    print("[2/5] Starting compositor pacer...")
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

    // -- Step 3: Connect to Elixir Server ---------------------------------------
    print("[3/5] Connecting to Elixir server at \(options.host):\(options.port)...")
    let streamer = FrameStreamer(host: options.host, port: options.port)
    do {
        try await streamer.connect()
    } catch {
        pacer.stop()
        display.teardown()
        print("  FAILED: \(error.localizedDescription)")
        print("  Is the Elixir server running? Start it with: cd server && mix phx.server")
        throw error
    }
    print("  OK  TCP connection established (TCP_NODELAY enabled)")
    print()

    // -- Step 4: Start Frame Capture --------------------------------------------
    print("[4/5] Starting frame capture (2 fps)...")
    let producer: FrameProducer
    do {
        producer = try await FrameProducer(
            displayID: display.displayID,
            width: preset.width,
            height: preset.height,
            frameRate: 2
        )
    } catch {
        await streamer.disconnect()
        pacer.stop()
        display.teardown()
        print("  FAILED: \(error.localizedDescription)")
        throw error
    }

    try await producer.start()
    print("  OK  ScreenCaptureKit stream active")
    print()

    // -- Step 5: Capture -> Greyscale -> Stream Loop ----------------------------
    print("[5/5] Streaming frames to server (Ctrl-C to stop)...")
    print("  Format: greyscale \(preset.width)x\(preset.height) (\(preset.width * preset.height) bytes/frame)")
    print()

    var frameCount = 0
    var bytesSent: UInt64 = 0
    let startTime = Date()
    let deadline = startTime.addingTimeInterval(options.duration)

    for await frame in producer.frames {
        // Skip frames without pixel data (status-only frames from SCK).
        guard let surface = frame.surface else { continue }

        // Extract BGRA pixel data from the IOSurface.
        guard let bgraData = extractBGRA(from: surface, width: preset.width, height: preset.height) else {
            print("  WARN: Could not read IOSurface for frame \(frameCount + 1)")
            continue
        }

        // Convert BGRA -> greyscale (temporary Swift impl, Zig FFI later).
        let greyData = toGreyscale(bgra: bgraData, width: preset.width, height: preset.height)

        // Stream to Elixir server. First frame is always a keyframe.
        let isKeyframe = (frameCount == 0)
        do {
            try await streamer.sendFrame(data: greyData, isKeyframe: isKeyframe, isColor: false)
        } catch {
            print("  ERROR: Send failed on frame \(frameCount + 1): \(error.localizedDescription)")
            print("  Connection may have been lost. Stopping.")
            break
        }

        frameCount += 1
        bytesSent += UInt64(greyData.count)

        // Print periodic status every 10 frames.
        if frameCount % 10 == 0 || frameCount == 1 {
            let elapsed = Date().timeIntervalSince(startTime)
            let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
            let mbSent = Double(bytesSent) / (1024 * 1024)
            print("  [\(String(format: "%6.1f", elapsed))s] frames=\(frameCount)  fps=\(String(format: "%.1f", fps))  sent=\(String(format: "%.1f", mbSent)) MB  seq=\(await streamer.framesSent)")
        }

        if Date() >= deadline {
            print()
            print("  Duration limit reached (\(Int(options.duration))s).")
            break
        }
    }

    // -- Cleanup ---------------------------------------------------------------
    await producer.stop()
    await streamer.disconnect()
    pacer.stop()
    display.teardown()

    let totalElapsed = Date().timeIntervalSince(startTime)
    let avgFps = totalElapsed > 0 ? Double(frameCount) / totalElapsed : 0
    let totalMB = Double(bytesSent) / (1024 * 1024)

    print()
    print("╔══════════════════════════════════════════════════╗")
    print("║                   Summary                        ║")
    print("╠══════════════════════════════════════════════════╣")
    print("║  Frames captured:  \(String(format: "%-29d", frameCount)) ║")
    print("║  Average FPS:      \(String(format: "%-29.2f", avgFps)) ║")
    print("║  Data sent:        \(String(format: "%-26.2f", totalMB)) MB ║")
    print("║  Duration:         \(String(format: "%-27.1f", totalElapsed)) s ║")
    print("╚══════════════════════════════════════════════════╝")
    print()
    print("[EnableCLI] Pipeline: VirtualDisplay -> Pacer -> Capture -> Greyscale -> TCP -> Elixir")
}

// -- Run --------------------------------------------------------------------

// We need an NSApplication for the compositor pacer window to work,
// but we don't want a full app lifecycle. A simple async entry suffices.

do {
    try await runStreamingPipeline()
} catch {
    print("\nFATAL: \(error.localizedDescription)")
    exit(1)
}
