// --------------------------------------------------------------------------
// InputReceiver.swift - Deserialize and inject Boox input events on macOS
//
// Handles the Boox-to-Mac input path: deserializes 20-byte input packets
// from the transport layer and injects them as native macOS events using
// CGEvent. Stylus events become tablet events with pressure and tilt;
// touch events become mouse events; scroll events become scroll wheel events.
//
// Learning note (CGEvent tablet events):
//   macOS supports pressure-sensitive tablet input through CGEvent's
//   tablet event fields. A regular mouse event becomes a tablet event
//   when you set CGEventField values for pressure, tilt, and tablet ID.
//   This is how Wacom drivers work — they create CGEvents with tablet
//   metadata, and apps like Photoshop read those fields for brush dynamics.
//
//   Key CGEventField values for tablet events:
//   - mouseEventPressure (Float): 0.0 to 1.0
//   - tabletEventTiltX (SInt32): -32767 to 32767 (we map from degrees)
//   - tabletEventTiltY (SInt32): -32767 to 32767
//   - tabletEventPointX/Y (SInt32): absolute position
//
// Learning note (stale event filtering):
//   E-ink display refresh takes 200-600ms, during which input events
//   pile up. Injecting stale events (>100ms old) causes the cursor to
//   "teleport" through old positions. We drop stale events entirely
//   and only inject the latest ones for smooth cursor tracking.
//
// Input packet format (20 bytes, from stylus-input spec):
// | Offset | Size | Field     | Type                                    |
// |--------|------|-----------|-----------------------------------------|
// | 0      | 1    | type      | uint8: 0x01=stylus, 0x02=touch, etc.   |
// | 1      | 4    | x         | float32 (normalized 0.0-1.0)            |
// | 5      | 4    | y         | float32 (normalized 0.0-1.0)            |
// | 9      | 2    | pressure  | uint16 (0-4095)                         |
// | 11     | 2    | tilt_x    | int16 (degrees)                         |
// | 13     | 2    | tilt_y    | int16 (degrees)                         |
// | 15     | 1    | flags     | uint8: bit0=down, bit1=hover, bit2=eraser |
// | 16     | 4    | timestamp | uint32 (ms since session start)         |
// --------------------------------------------------------------------------

import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Input Event Types

/// The type of input event, matching the wire protocol's type byte.
public enum InputEventType: UInt8, Sendable {
    case stylus = 0x01
    case touch  = 0x02
    case scroll = 0x03
    case pinch  = 0x04
}

/// Flags encoded in the input packet's flags byte.
public struct InputEventFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Bit 0: The pen/finger is in contact with the surface (down).
    public static let down   = InputEventFlags(rawValue: 1 << 0)

    /// Bit 1: The pen is hovering near the surface (proximity).
    public static let hover  = InputEventFlags(rawValue: 1 << 1)

    /// Bit 2: The eraser end of the stylus is active.
    public static let eraser = InputEventFlags(rawValue: 1 << 2)
}

/// A deserialized input event from the Boox device.
///
/// Coordinates are normalized (0.0 to 1.0) so the Mac side can map them
/// to any virtual display resolution. Pressure uses the Wacom EMR range
/// (0-4095) which we normalize to 0.0-1.0 for CGEvent injection.
public struct InputEvent: Sendable {
    /// The type of input event.
    public let type: InputEventType

    /// Normalized X coordinate (0.0 = left, 1.0 = right).
    public let x: Float32

    /// Normalized Y coordinate (0.0 = top, 1.0 = bottom).
    public let y: Float32

    /// Raw pressure from the Wacom EMR digitizer (0-4095).
    public let pressure: UInt16

    /// Stylus tilt on the X axis in degrees.
    public let tiltX: Int16

    /// Stylus tilt on the Y axis in degrees.
    public let tiltY: Int16

    /// Packed flag bits (down, hover, eraser).
    public let flags: InputEventFlags

    /// Milliseconds since the Boox session started.
    public let timestamp: UInt32

    // MARK: - Derived Properties

    /// Whether the pen/finger is touching the surface.
    public var isDown: Bool { flags.contains(.down) }

    /// Whether the pen is hovering (proximity detection).
    public var isHover: Bool { flags.contains(.hover) }

    /// Whether the eraser end of the stylus is active.
    public var isEraser: Bool { flags.contains(.eraser) }

    /// Pressure normalized to 0.0-1.0 range for CGEvent injection.
    ///
    /// The Wacom EMR digitizer provides 4096 pressure levels (0-4095).
    /// CGEvent expects a Float in [0.0, 1.0].
    public var normalizedPressure: Double {
        Double(pressure) / 4095.0
    }

    // MARK: - Serialization

    /// Deserialize a 20-byte input packet from wire format.
    ///
    /// - Parameter data: Exactly 20 bytes in the input packet format.
    /// - Returns: The deserialized InputEvent, or nil if data is malformed.
    public static func deserialize(from data: Data) -> InputEvent? {
        guard data.count >= WireProtocol.inputPacketSize else { return nil }

        let startIndex = data.startIndex

        // Byte 0: type
        guard let type = InputEventType(rawValue: data[startIndex]) else { return nil }

        // Bytes 1-4: x (float32, big-endian per spec)
        let x: Float32 = data.withUnsafeBytes { buffer in
            var raw = buffer.load(fromByteOffset: 1, as: UInt32.self)
            raw = UInt32(bigEndian: raw)
            return Float32(bitPattern: raw)
        }

        // Bytes 5-8: y (float32, big-endian per spec)
        let y: Float32 = data.withUnsafeBytes { buffer in
            var raw = buffer.load(fromByteOffset: 5, as: UInt32.self)
            raw = UInt32(bigEndian: raw)
            return Float32(bitPattern: raw)
        }

        // Bytes 9-10: pressure (uint16, big-endian per spec)
        let pressure: UInt16 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 9, as: UInt16.self)
            return UInt16(bigEndian: raw)
        }

        // Bytes 11-12: tilt_x (int16, big-endian per spec)
        let tiltX: Int16 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 11, as: Int16.self)
            return Int16(bigEndian: raw)
        }

        // Bytes 13-14: tilt_y (int16, big-endian per spec)
        let tiltY: Int16 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 13, as: Int16.self)
            return Int16(bigEndian: raw)
        }

        // Byte 15: flags
        let flags = InputEventFlags(rawValue: data[startIndex + 15])

        // Bytes 16-19: timestamp (uint32, big-endian per spec)
        let timestamp: UInt32 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 16, as: UInt32.self)
            return UInt32(bigEndian: raw)
        }

        return InputEvent(
            type: type,
            x: x,
            y: y,
            pressure: pressure,
            tiltX: tiltX,
            tiltY: tiltY,
            flags: flags,
            timestamp: timestamp
        )
    }

    /// Serialize this event into a 20-byte packet for wire transmission.
    ///
    /// Used primarily for testing — the Boox side serializes in Kotlin.
    public func serialize() -> Data {
        var data = Data(capacity: WireProtocol.inputPacketSize)

        // Byte 0: type
        data.append(type.rawValue)

        // Bytes 1-4: x (float32, big-endian)
        var xBits = x.bitPattern.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &xBits) { Array($0) })

        // Bytes 5-8: y (float32, big-endian)
        var yBits = y.bitPattern.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &yBits) { Array($0) })

        // Bytes 9-10: pressure (uint16, big-endian)
        var pressureBE = pressure.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &pressureBE) { Array($0) })

        // Bytes 11-12: tilt_x (int16, big-endian)
        var tiltXBE = tiltX.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &tiltXBE) { Array($0) })

        // Bytes 13-14: tilt_y (int16, big-endian)
        var tiltYBE = tiltY.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &tiltYBE) { Array($0) })

        // Byte 15: flags
        data.append(flags.rawValue)

        // Bytes 16-19: timestamp (uint32, big-endian)
        var tsBE = timestamp.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &tsBE) { Array($0) })

        return data
    }
}

// MARK: - InputReceiver

/// Receives input events from the transport layer and injects them as
/// native macOS events via CGEvent.
///
/// InputReceiver runs a continuous processing loop:
/// 1. Receive serialized input data from the ConnectionManager delegate.
/// 2. Deserialize 20-byte packets into InputEvent structs.
/// 3. Filter stale events (>100ms old).
/// 4. Map normalized coordinates to the virtual display's pixel space.
/// 5. Create and post CGEvents with appropriate tablet metadata.
///
/// Learning note (Accessibility permission):
///   CGEvent posting requires the "Accessibility" permission in
///   System Settings > Privacy & Security. Without it, CGEventPost
///   silently fails. We check this at startup and surface an error
///   if the permission isn't granted.
public actor InputReceiver {

    /// The virtual display's resolution, used to map normalized coordinates
    /// to absolute pixel positions.
    private var displayWidth: CGFloat
    private var displayHeight: CGFloat

    /// Session start time on the Mac side, used for stale event detection.
    private var sessionStartTime: ContinuousClock.Instant

    /// Maximum age (in milliseconds) before an input event is considered stale.
    private let staleThresholdMs: UInt32 = 100

    /// Tracks whether the pen/finger is currently down, for generating
    /// correct mouse button up/down transitions.
    private var isPenDown = false

    /// The last known pen position, used for move events.
    private var lastPosition: CGPoint = .zero

    /// Approximate offset between the Boox's session timestamp base and
    /// our local monotonic clock base. Calibrated on the first received event.
    private var timestampOffset: Int64?

    // MARK: - Initialization

    /// Create an InputReceiver for a virtual display of the given resolution.
    ///
    /// - Parameters:
    ///   - displayWidth: The virtual display width in pixels (e.g., 1240).
    ///   - displayHeight: The virtual display height in pixels (e.g., 930).
    public init(displayWidth: CGFloat, displayHeight: CGFloat) {
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.sessionStartTime = .now
    }

    /// Update the virtual display resolution (e.g., after a resolution change).
    public func updateDisplaySize(width: CGFloat, height: CGFloat) {
        self.displayWidth = width
        self.displayHeight = height
    }

    /// Reset the session clock. Call this on reconnection.
    public func resetSession() {
        sessionStartTime = .now
        timestampOffset = nil
        isPenDown = false
    }

    // MARK: - Event Processing

    /// Process a buffer of raw input data from the transport layer.
    ///
    /// The buffer may contain multiple 20-byte input packets concatenated.
    /// Each is deserialized, filtered for staleness, and injected.
    ///
    /// - Parameter data: Raw input data (must be a multiple of 20 bytes).
    public func processInputData(_ data: Data) {
        let packetSize = WireProtocol.inputPacketSize
        let count = data.count / packetSize

        for i in 0..<count {
            let offset = data.startIndex + i * packetSize
            let packetData = data.subdata(in: offset..<(offset + packetSize))

            guard let event = InputEvent.deserialize(from: packetData) else {
                continue  // Skip malformed packets.
            }

            // Calibrate timestamp offset on the first event.
            if timestampOffset == nil {
                let nowMs = currentTimeMs()
                timestampOffset = Int64(nowMs) - Int64(event.timestamp)
            }

            // Stale event detection: drop events older than 100ms.
            if isStale(event) {
                continue
            }

            injectEvent(event)
        }
    }

    // MARK: - Stale Detection

    /// Check if an event is too old to inject.
    ///
    /// We compare the event's timestamp (ms since Boox session start) with
    /// our local clock, using the calibrated offset. Events older than
    /// `staleThresholdMs` are dropped.
    private func isStale(_ event: InputEvent) -> Bool {
        guard let offset = timestampOffset else { return false }

        let localEventTimeMs = Int64(event.timestamp) + offset
        let nowMs = currentTimeMs()
        let ageMs = nowMs - localEventTimeMs

        return ageMs > Int64(staleThresholdMs)
    }

    /// Current time in milliseconds since an arbitrary epoch, using the
    /// continuous (monotonic) clock.
    private func currentTimeMs() -> Int64 {
        let elapsed = ContinuousClock.now - sessionStartTime
        let seconds = elapsed.components.seconds
        let attoseconds = elapsed.components.attoseconds
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    // MARK: - CGEvent Injection

    /// Inject a single input event as a native macOS event.
    ///
    /// This is the core mapping logic:
    /// - Stylus events become tablet mouse events (with pressure + tilt).
    /// - Touch events become regular mouse events.
    /// - Scroll events become scroll wheel events.
    private func injectEvent(_ event: InputEvent) {
        // Map normalized coordinates to display pixel space.
        let pixelX = CGFloat(event.x) * displayWidth
        let pixelY = CGFloat(event.y) * displayHeight
        let point = CGPoint(x: pixelX, y: pixelY)
        lastPosition = point

        switch event.type {
        case .stylus:
            injectStylusEvent(event, at: point)
        case .touch:
            injectTouchEvent(event, at: point)
        case .scroll:
            injectScrollEvent(event, at: point)
        case .pinch:
            injectPinchEvent(event, at: point)
        }
    }

    /// Inject a stylus event as a CGEvent tablet mouse event.
    ///
    /// Learning note (tablet event creation):
    ///   We create a regular mouse event (move/down/up) and then attach
    ///   tablet metadata (pressure, tilt) via CGEventSetDoubleValueField
    ///   and CGEventSetIntegerValueField. This is the same technique
    ///   used by Wacom's macOS driver.
    private func injectStylusEvent(_ event: InputEvent, at point: CGPoint) {
        let eventType: CGEventType
        let mouseButton = CGMouseButton.left

        if event.isDown && !isPenDown {
            // Pen just touched down.
            eventType = .leftMouseDown
            isPenDown = true
        } else if !event.isDown && isPenDown {
            // Pen just lifted.
            eventType = .leftMouseUp
            isPenDown = false
        } else if event.isDown {
            // Pen is dragging.
            eventType = .leftMouseDragged
        } else {
            // Pen is hovering (move without button).
            eventType = .mouseMoved
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ) else { return }

        // Attach tablet pressure (0.0 - 1.0).
        cgEvent.setDoubleValueField(.mouseEventPressure, value: event.normalizedPressure)

        // Attach tablet tilt.
        // CGEvent tilt range is implementation-defined but typically uses
        // the full Int32 range. We map degrees (-90..90) to (-32767..32767).
        let tiltScale = 32767.0 / 90.0
        let tiltXMapped = Int64(Double(event.tiltX) * tiltScale)
        let tiltYMapped = Int64(Double(event.tiltY) * tiltScale)
        cgEvent.setIntegerValueField(.tabletEventTiltX, value: tiltXMapped)
        cgEvent.setIntegerValueField(.tabletEventTiltY, value: tiltYMapped)

        // Mark this as a tablet event so apps recognize the pressure/tilt data.
        cgEvent.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        cgEvent.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))

        // Post to the HID event system.
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Inject a touch event as a regular mouse event.
    ///
    /// Touch events map to standard mouse behavior:
    /// - Touch down = left mouse down
    /// - Touch up = left mouse up
    /// - Touch move (while down) = left mouse dragged
    /// - Touch move (while up) = mouse moved
    private func injectTouchEvent(_ event: InputEvent, at point: CGPoint) {
        let eventType: CGEventType
        let mouseButton = CGMouseButton.left

        if event.isDown && !isPenDown {
            eventType = .leftMouseDown
            isPenDown = true
        } else if !event.isDown && isPenDown {
            eventType = .leftMouseUp
            isPenDown = false
        } else if event.isDown {
            eventType = .leftMouseDragged
        } else {
            eventType = .mouseMoved
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ) else { return }

        cgEvent.post(tap: .cghidEventTap)
    }

    /// Inject a scroll event as a CGEvent scroll wheel event.
    ///
    /// The x and y fields are repurposed for scroll deltas:
    /// - x = horizontal scroll delta (normalized, we scale to discrete lines)
    /// - y = vertical scroll delta
    ///
    /// Learning note (CGEventCreateScrollWheelEvent2):
    ///   macOS scroll events use "lines" as the unit for discrete scrolling.
    ///   We multiply the normalized delta by a sensitivity factor to convert
    ///   the Boox's smooth scroll gesture into discrete line counts.
    private func injectScrollEvent(_ event: InputEvent, at point: CGPoint) {
        // Scale normalized scroll deltas to line counts.
        // A full swipe across the screen (~1.0 delta) should scroll ~20 lines.
        let scrollSensitivity: Float32 = 20.0
        let deltaY = Int32(event.y * scrollSensitivity)
        let deltaX = Int32(event.x * scrollSensitivity)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }

        scrollEvent.post(tap: .cgSessionEventTap)
    }

    /// Inject a pinch event as a magnification gesture event.
    ///
    /// Pinch-to-zoom on the Boox maps to macOS magnification gestures
    /// (the same as trackpad pinch). The pressure field is repurposed as
    /// the scale factor (encoded as uint16: 1000 = 1.0x, 2000 = 2.0x).
    ///
    /// Learning note (magnification events):
    ///   macOS magnification gestures are injected via NSEvent, not CGEvent.
    ///   However, since we're in a pure CGEvent context, we approximate
    ///   pinch-to-zoom as Cmd+scroll, which most apps interpret as zoom.
    private func injectPinchEvent(_ event: InputEvent, at point: CGPoint) {
        // Decode scale factor from pressure field.
        // pressure 1000 = 1.0x (neutral), >1000 = zoom in, <1000 = zoom out.
        let scaleFactor = Float32(event.pressure) / 1000.0
        let delta = scaleFactor - 1.0  // Positive = zoom in, negative = zoom out

        // Convert to scroll delta (Cmd+scroll = zoom in most apps).
        let zoomLines = Int32(delta * 10.0)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: zoomLines,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        // Set the Cmd modifier flag so apps interpret this as zoom.
        scrollEvent.flags = CGEventFlags.maskCommand

        scrollEvent.post(tap: .cgSessionEventTap)
    }

    // MARK: - Permission Check

    /// Check if the Accessibility permission is granted.
    ///
    /// CGEvent posting requires the app to be trusted for Accessibility.
    /// Without this permission, all CGEventPost calls silently fail.
    ///
    /// - Parameter prompt: If true, shows the system permission prompt.
    /// - Returns: `true` if the permission is already granted.
    public nonisolated func checkAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
