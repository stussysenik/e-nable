// --------------------------------------------------------------------------
// FrameProducer.swift - ScreenCaptureKit-based frame capture
//
// This is the heart of the pipeline. FrameProducer:
//   1. Finds the virtual display in SCShareableContent
//   2. Creates an SCStream configured for that display
//   3. Delivers frames as IOSurface-backed CMSampleBuffers
//
// Callers receive frames via an AsyncStream — no delegate callbacks to
// manage, no retain-cycle footguns.
//
// Learning note (ScreenCaptureKit architecture):
//   SCStream needs three things:
//     - An SCContentFilter (what to capture — a display, window, or region)
//     - An SCStreamConfiguration (pixel format, size, frame rate)
//     - An SCStreamOutput (delegate that receives CMSampleBuffers)
//   We wrap the delegate in an internal class and bridge to AsyncStream.
// --------------------------------------------------------------------------

import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Frame

/// A captured frame containing the pixel data and metadata.
///
/// The `surface` property holds the IOSurface — zero-copy GPU memory that
/// can be read directly by the Zig dithering core via IOSurfaceGetBaseAddress.
public struct CapturedFrame: @unchecked Sendable {
    /// The raw sample buffer from ScreenCaptureKit.
    /// Note: CMSampleBuffer is not Sendable, but we treat frames as immutable
    /// data packets that flow through the pipeline in one direction.
    public let sampleBuffer: CMSampleBuffer

    /// The IOSurface backing the frame's pixel data.
    /// Nil only if ScreenCaptureKit delivered a status-only frame.
    public let surface: IOSurface?

    /// Presentation timestamp.
    public let timestamp: CMTime
}

// MARK: - FrameProducer

/// Captures frames from a virtual display using ScreenCaptureKit.
///
/// Usage:
/// ```swift
/// let producer = try await FrameProducer(displayID: virtualDisplay.displayID,
///                                         width: preset.width,
///                                         height: preset.height)
/// for await frame in producer.frames {
///     // Process frame.surface
/// }
/// ```
public final class FrameProducer: @unchecked Sendable {

    // MARK: - Properties

    private var stream: SCStream?
    private let streamOutput: StreamOutput
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    /// AsyncStream of captured frames. Consume this from an async context.
    public let frames: AsyncStream<CapturedFrame>

    /// The display ID we are capturing.
    public let displayID: CGDirectDisplayID

    // MARK: - Init

    /// Set up the capture pipeline for a specific display.
    ///
    /// - Parameters:
    ///   - displayID: The CGDirectDisplayID of the virtual display.
    ///   - width: Capture width in pixels.
    ///   - height: Capture height in pixels.
    ///   - frameRate: Target frames per second. For e-ink, 1-5 fps is typical.
    /// - Throws: CaptureError if the display is not found or stream setup fails.
    public init(
        displayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        frameRate: Int = 2
    ) async throws {
        self.displayID = displayID

        // -- 1. Find the display in shareable content ----------------------------

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.virtualDisplayNotInShareableContent
        }

        // -- 2. Build stream configuration ----------------------------------------

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height

        // BGRA is the most common pixel format on macOS and avoids color-space
        // conversion overhead. The Zig dithering core expects this layout.
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Minimum interval between frames. 1/frameRate seconds.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        // Capture only this display, no specific windows.
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        // -- 3. Wire up the async stream ------------------------------------------

        var capturedContinuation: AsyncStream<CapturedFrame>.Continuation!
        let capturedFrames = AsyncStream<CapturedFrame> { continuation in
            capturedContinuation = continuation
        }
        self.frames = capturedFrames
        self.continuation = capturedContinuation

        // -- 4. Create stream output handler --------------------------------------

        let output = StreamOutput(continuation: capturedContinuation)
        self.streamOutput = output

        // -- 5. Create and configure the SCStream ---------------------------------

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        self.stream = scStream
    }

    // MARK: - Start / Stop

    /// Begin frame capture. Frames appear on the `frames` AsyncStream.
    public func start() async throws {
        guard let stream = stream else {
            throw CaptureError.streamStartFailed(underlying: "Stream not initialized.")
        }
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamStartFailed(underlying: error.localizedDescription)
        }
    }

    /// Stop frame capture and clean up.
    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        continuation.finish()
    }
}

// MARK: - StreamOutput (SCStreamOutput Delegate)

/// Internal delegate that bridges SCStream callbacks to our AsyncStream.
///
/// Learning note (SCStreamOutput protocol):
///   ScreenCaptureKit calls `stream(_:didOutputSampleBuffer:of:)` on a
///   serial dispatch queue whenever a new frame is available. We push
///   each frame into the AsyncStream continuation — backpressure is handled
///   by the stream's `.minimumFrameInterval`.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {

    private let continuation: AsyncStream<CapturedFrame>.Continuation

    init(continuation: AsyncStream<CapturedFrame>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // We only care about screen frames, not audio.
        guard type == .screen else { return }

        // Extract the IOSurface from the sample buffer's image buffer.
        let surface: IOSurface?
        if let imageBuffer = sampleBuffer.imageBuffer {
            surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue()
        } else {
            surface = nil
        }

        let frame = CapturedFrame(
            sampleBuffer: sampleBuffer,
            surface: surface,
            timestamp: sampleBuffer.presentationTimeStamp
        )

        continuation.yield(frame)
    }
}
