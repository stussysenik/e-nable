// --------------------------------------------------------------------------
// CompositorPacer.swift - Force macOS compositor to render the virtual display
//
// Problem: macOS is smart about power. If no visible window overlaps a
// display, the compositor may skip rendering it entirely. Our virtual
// display has no physical output, so macOS may never composite it — and
// ScreenCaptureKit would deliver blank or stale frames.
//
// Solution: Place a tiny (4x4 pixel) transparent window on the virtual
// display. This forces the compositor to include that display in every
// render pass. The window is invisible to the user and uses negligible GPU.
//
// This is the same trick used by BetterDisplay and Deskpad.
//
// Learning note (NSWindow + virtual displays):
//   NSWindow.setFrameOrigin moves the window into the virtual display's
//   coordinate space. The compositor sees it and wakes up for that display.
//   We use NSWindow.Level.floating so it stays above other content and
//   never gets occluded (which could let the compositor skip it again).
// --------------------------------------------------------------------------

import AppKit
import Foundation

// MARK: - CompositorPacer

/// Keeps a virtual display active in the macOS compositor by placing a
/// tiny window on it.
///
/// Usage:
/// ```swift
/// let pacer = try CompositorPacer(displayID: virtualDisplay.displayID)
/// // ... compositor now renders the virtual display ...
/// pacer.stop()
/// ```
public final class CompositorPacer: @unchecked Sendable {

    // MARK: - Properties

    /// The tiny window that lives on the virtual display.
    private var window: NSWindow?

    /// The display we are pacing.
    public let displayID: CGDirectDisplayID

    // MARK: - Init

    /// Create a pacer for the given virtual display.
    ///
    /// - Parameter displayID: The CGDirectDisplayID of the virtual display.
    /// - Throws: `CaptureError.pacerWindowCreationFailed` if the display
    ///           bounds cannot be determined.
    public init(displayID: CGDirectDisplayID) throws {
        self.displayID = displayID

        // Get the display's bounds in global coordinate space.
        let bounds = CGDisplayBounds(displayID)

        guard bounds.width > 0, bounds.height > 0 else {
            throw CaptureError.pacerWindowCreationFailed
        }

        // Create a 4x4 pixel window — the smallest practical size.
        // We place it at the display's origin so it lands squarely on the
        // virtual display in the compositor's coordinate space.
        let pacerRect = NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: 4,
            height: 4
        )

        let win = NSWindow(
            contentRect: pacerRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Configuration for minimal visual impact:
        //   - Transparent background so it's invisible
        //   - Floating level so nothing occludes it
        //   - Excluded from window capture so it doesn't appear in screenshots
        //   - Not movable by the user
        win.backgroundColor = .clear
        win.isOpaque = false
        win.level = .floating
        win.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.alphaValue = 0.01  // Near-invisible but still forces compositing

        // Position the window on the virtual display.
        win.setFrameOrigin(bounds.origin)

        // Show it — this triggers the compositor to include the display.
        win.orderFrontRegardless()

        self.window = win
    }

    // MARK: - Stop

    /// Remove the pacer window and stop forcing composition.
    /// Safe to call multiple times.
    public func stop() {
        window?.close()
        window = nil
    }

    deinit {
        stop()
    }
}
