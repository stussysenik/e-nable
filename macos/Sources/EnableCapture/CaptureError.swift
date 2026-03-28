// --------------------------------------------------------------------------
// CaptureError.swift - Typed error surface for the capture pipeline
//
// Every layer of the pipeline (virtual display, frame capture, compositor)
// funnels failures into this single enum so callers get structured errors
// instead of raw NSError / String noise.
//
// Learning note (Swift patterns):
//   Conforming to LocalizedError lets Foundation tooling (e.g. `localizedDescription`)
//   pick up our custom messages automatically.
// --------------------------------------------------------------------------

import Foundation

/// All errors that can occur during the screen capture pipeline.
///
/// Organized by pipeline stage so call-sites can pattern-match on the
/// category they care about and propagate the rest.
public enum CaptureError: LocalizedError, Sendable {

    // MARK: - Virtual Display Errors

    /// The private CGVirtualDisplay symbols could not be resolved via dlsym.
    /// This usually means the macOS version removed or renamed the SPI.
    case virtualDisplaySymbolsUnavailable

    /// CGVirtualDisplayCreate (or equivalent) returned nil / a null descriptor.
    case virtualDisplayCreationFailed(underlying: String)

    /// The requested resolution is not achievable with current hardware.
    case unsupportedResolution(width: Int, height: Int)

    // MARK: - ScreenCaptureKit Errors

    /// SCShareableContent.excludingDesktopWindows failed or returned no displays.
    case noDisplaysFound

    /// The virtual display could not be located in the shareable content list.
    case virtualDisplayNotInShareableContent

    /// SCStream failed to start or delivered an error callback.
    case streamStartFailed(underlying: String)

    /// A frame arrived but its IOSurface / CVPixelBuffer was nil.
    case frameSurfaceMissing

    // MARK: - Compositor Pacer Errors

    /// The 4x4 px off-screen window could not be created.
    case pacerWindowCreationFailed

    /// The display link (or timer) failed to start.
    case pacerTimerFailed(underlying: String)

    // MARK: - General

    /// Permission denied — user has not granted Screen Recording access.
    case permissionDenied

    /// Catch-all for unexpected conditions. Includes a description for debugging.
    case internalError(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .virtualDisplaySymbolsUnavailable:
            return "CGVirtualDisplay private symbols could not be loaded via dlsym."
        case .virtualDisplayCreationFailed(let msg):
            return "Virtual display creation failed: \(msg)"
        case .unsupportedResolution(let w, let h):
            return "Unsupported resolution: \(w)x\(h)."
        case .noDisplaysFound:
            return "No displays found via SCShareableContent."
        case .virtualDisplayNotInShareableContent:
            return "Virtual display not found in shareable content list."
        case .streamStartFailed(let msg):
            return "SCStream start failed: \(msg)"
        case .frameSurfaceMissing:
            return "Frame arrived with nil IOSurface."
        case .pacerWindowCreationFailed:
            return "Compositor pacer window creation failed."
        case .pacerTimerFailed(let msg):
            return "Compositor pacer timer failed: \(msg)"
        case .permissionDenied:
            return "Screen Recording permission denied. Grant access in System Settings > Privacy & Security."
        case .internalError(let msg):
            return "Internal error: \(msg)"
        }
    }
}
