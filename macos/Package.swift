// swift-tools-version: 5.9
// --------------------------------------------------------------------------
// Package.swift - SPM manifest for the EnableCapture macOS screen capture layer
//
// Targets:
//   - EnableCapture (library): Core capture pipeline — virtual display creation,
//     ScreenCaptureKit frame production, and compositor pacing.
//   - EnableCLI (executable): Minimal CLI entry point for testing the pipeline.
//
// Platform: macOS 14+ (Sonoma) required for ScreenCaptureKit improvements
//           and CGVirtualDisplay private API availability.
// --------------------------------------------------------------------------

import PackageDescription

let package = Package(
    name: "EnableCapture",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Library product — consumed by the Flutter FFI bridge or other Swift code.
        .library(
            name: "EnableCapture",
            targets: ["EnableCapture"]
        ),
        // Executable product — standalone CLI for quick testing.
        .executable(
            name: "EnableCLI",
            targets: ["EnableCLI"]
        ),
    ],
    targets: [
        .target(
            name: "EnableCapture",
            path: "Sources/EnableCapture",
            linkerSettings: [
                // ScreenCaptureKit framework for SCStream / SCShareableContent
                .linkedFramework("ScreenCaptureKit"),
                // CoreGraphics for CGDirectDisplay, CGImage, color spaces
                .linkedFramework("CoreGraphics"),
                // AppKit for NSWindow (compositor pacer trick)
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "EnableCLI",
            dependencies: ["EnableCapture"],
            path: "Sources/EnableCLI"
        ),
    ]
)
