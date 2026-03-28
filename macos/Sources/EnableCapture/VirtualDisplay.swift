// --------------------------------------------------------------------------
// VirtualDisplay.swift - Create a headless virtual display via private SPI
//
// macOS has no public API for creating virtual displays. We use dlsym to
// resolve CGVirtualDisplay* symbols from CoreGraphics at runtime. This is
// the same technique used by BetterDisplay, Deskpad, and similar utilities.
//
// Why dlsym instead of bridging headers?
//   1. No need to ship a .tbd or link against a private framework.
//   2. Fails gracefully at runtime instead of crashing at link time if
//      Apple removes the symbols.
//   3. Keeps the build vanilla SPM — no Xcode project required.
//
// Learning note (dlsym pattern):
//   `dlsym(RTLD_DEFAULT, "symbol")` searches all loaded images. We cast
//   the returned pointer to the expected function signature using
//   `unsafeBitCast`. This is inherently unsafe — the compiler cannot verify
//   the signature matches — but it's the standard approach for SPI access.
// --------------------------------------------------------------------------

import CoreGraphics
import Foundation

// MARK: - CGVirtualDisplay SPI Types

/// Opaque type returned by CGVirtualDisplayCreate.
/// We never dereference this — it's just a handle we pass back to CG.
private typealias CGVirtualDisplayRef = UnsafeMutableRawPointer

/// Settings dictionary keys (string constants from the SPI).
private let kCGVirtualDisplaySettingsWidth      = "Width" as CFString
private let kCGVirtualDisplaySettingsHeight     = "Height" as CFString
private let kCGVirtualDisplaySettingsPPI        = "ppiWidth" as CFString
private let kCGVirtualDisplaySettingsPPIHeight  = "ppiHeight" as CFString

// MARK: - Function Signatures

/// `CGVirtualDisplayCreate(settings: CFDictionary) -> CGVirtualDisplayRef?`
private typealias CreateFn  = @convention(c) (CFDictionary) -> CGVirtualDisplayRef?
/// `CGVirtualDisplayDestroy(display: CGVirtualDisplayRef)`
private typealias DestroyFn = @convention(c) (CGVirtualDisplayRef) -> Void

// MARK: - Symbol Resolution

/// Lazily resolved function pointers. If any symbol is missing the entire
/// pipeline refuses to start with `.virtualDisplaySymbolsUnavailable`.
private struct Symbols {
    static let create: CreateFn? = {
        guard let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGVirtualDisplayCreate") else { return nil }
        return unsafeBitCast(ptr, to: CreateFn.self)
    }()

    static let destroy: DestroyFn? = {
        guard let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGVirtualDisplayDestroy") else { return nil }
        return unsafeBitCast(ptr, to: DestroyFn.self)
    }()
}

// MARK: - VirtualDisplay

/// A headless virtual display backed by CoreGraphics private SPI.
///
/// Usage:
/// ```swift
/// let display = try VirtualDisplay(preset: .tabUltraCPro)
/// print("Display ID:", display.displayID)
/// // ... capture frames via FrameProducer ...
/// display.teardown()
/// ```
///
/// The display is automatically torn down in `deinit`, but calling
/// `teardown()` explicitly is recommended for deterministic cleanup.
public final class VirtualDisplay: @unchecked Sendable {

    // MARK: - Properties

    /// The CGDirectDisplayID assigned to this virtual display by CoreGraphics.
    /// Use this to locate the display in SCShareableContent.
    public private(set) var displayID: CGDirectDisplayID = 0

    /// The resolution this display was created at.
    public let preset: ResolutionPreset

    /// Opaque handle — must be kept alive for the display to remain active.
    private var displayRef: CGVirtualDisplayRef?

    // MARK: - Init

    /// Create a new virtual display at the given preset resolution.
    ///
    /// - Parameter preset: The Boox panel preset defining width/height.
    /// - Throws: `CaptureError.virtualDisplaySymbolsUnavailable` if SPI is missing,
    ///           `CaptureError.virtualDisplayCreationFailed` if CG rejects the settings.
    public init(preset: ResolutionPreset) throws {
        self.preset = preset

        guard let createFn = Symbols.create, Symbols.destroy != nil else {
            throw CaptureError.virtualDisplaySymbolsUnavailable
        }

        // Build the settings dictionary.
        let settings: [CFString: Any] = [
            kCGVirtualDisplaySettingsWidth:     preset.width,
            kCGVirtualDisplaySettingsHeight:    preset.height,
            kCGVirtualDisplaySettingsPPI:       226,          // Retina-class PPI
            kCGVirtualDisplaySettingsPPIHeight: 226,
        ]

        guard let ref = createFn(settings as CFDictionary) else {
            throw CaptureError.virtualDisplayCreationFailed(
                underlying: "CGVirtualDisplayCreate returned nil for \(preset.displayName)"
            )
        }

        self.displayRef = ref

        // Discover our new display's ID from the active display list.
        // After creation the new display appears in CGGetActiveDisplayList.
        self.displayID = try Self.findNewDisplayID(width: preset.width, height: preset.height)
    }

    deinit {
        teardown()
    }

    // MARK: - Teardown

    /// Explicitly destroy the virtual display, releasing the CG resources.
    /// Safe to call multiple times.
    public func teardown() {
        guard let ref = displayRef else { return }
        Symbols.destroy?(ref)
        displayRef = nil
        displayID = 0
    }

    // MARK: - Display Discovery

    /// Walk the active display list and find one matching our dimensions.
    ///
    /// Learning note (CGGetActiveDisplayList):
    ///   This CoreGraphics function fills a buffer with all active display IDs.
    ///   We call it twice: first with 0 to get the count, then with a buffer.
    private static func findNewDisplayID(width: Int, height: Int) throws -> CGDirectDisplayID {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        guard displayCount > 0 else {
            throw CaptureError.virtualDisplayCreationFailed(
                underlying: "No active displays found after creation."
            )
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        // Find a display whose pixel dimensions match our preset.
        for id in displays {
            let w = CGDisplayPixelsWide(id)
            let h = CGDisplayPixelsHigh(id)
            if w == width && h == height {
                return id
            }
        }

        // If no exact match, return the last display (most recently added).
        // This is a heuristic — virtual displays typically appear at the end.
        if let last = displays.last, last != CGMainDisplayID() {
            return last
        }

        throw CaptureError.virtualDisplayCreationFailed(
            underlying: "Could not identify virtual display in active display list."
        )
    }
}
