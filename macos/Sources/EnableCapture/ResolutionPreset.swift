// --------------------------------------------------------------------------
// ResolutionPreset.swift - Boox e-ink panel resolution presets
//
// Each preset corresponds to an actual Boox e-ink display panel.
// The virtual display we create will match one of these exactly so the
// macOS compositor renders at the native panel resolution — no scaling
// artifacts, no wasted bandwidth.
//
// Learning note (Swift enums):
//   Swift enums can carry stored properties via computed getters.
//   CaseIterable gives us `.allCases` for free — handy for CLI menus.
// --------------------------------------------------------------------------

import Foundation

/// Native resolutions for supported Boox e-ink panels.
///
/// Use these presets when creating a `VirtualDisplay` so the frame buffer
/// size exactly matches the physical panel — pixel-perfect 1:1 mapping.
public enum ResolutionPreset: String, CaseIterable, Sendable {

    // MARK: - Presets

    /// Boox Tab Ultra C Pro — 10.3" color e-ink, 2480 x 1860
    case tabUltraCPro = "tab-ultra-c-pro"

    /// Boox Note Air 3 C — 10.3" color e-ink, 2480 x 1860
    /// Same panel resolution as Tab Ultra C Pro.
    case noteAir3C = "note-air3-c"

    /// Boox Go 10.3 — 10.3" monochrome e-ink, 1404 x 1872
    case go103 = "go-10.3"

    /// Boox Tab Mini C — 7.8" color e-ink, 1404 x 1872
    /// Same resolution as Go 10.3 despite different panel tech.
    case tabMiniC = "tab-mini-c"

    // MARK: - Dimensions

    /// Pixel width of this preset's panel (landscape orientation).
    public var width: Int {
        switch self {
        case .tabUltraCPro, .noteAir3C:
            return 2480
        case .go103, .tabMiniC:
            return 1404
        }
    }

    /// Pixel height of this preset's panel (landscape orientation).
    public var height: Int {
        switch self {
        case .tabUltraCPro, .noteAir3C:
            return 1860
        case .go103, .tabMiniC:
            return 1872
        }
    }

    /// Convenience tuple — `(width, height)`.
    public var size: (width: Int, height: Int) {
        (width, height)
    }

    /// A human-readable label for CLI / logging output.
    public var displayName: String {
        switch self {
        case .tabUltraCPro: return "Boox Tab Ultra C Pro (2480x1860)"
        case .noteAir3C:    return "Boox Note Air 3 C (2480x1860)"
        case .go103:        return "Boox Go 10.3 (1404x1872)"
        case .tabMiniC:     return "Boox Tab Mini C (1404x1872)"
        }
    }

    /// Total pixel count — useful for buffer allocation sizing.
    public var pixelCount: Int { width * height }
}
