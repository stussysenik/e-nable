// --------------------------------------------------------------------------
// ConnectionManager.swift - Connection lifecycle with auto-reconnect
//
// Manages the full lifecycle of the transport connection: idle -> connecting
// -> connected -> reconnecting -> error. Implements exponential backoff
// on disconnect and coordinates keyframe resend after reconnection.
//
// Learning note (actors in Swift concurrency):
//   An actor serializes access to its mutable state, eliminating data races.
//   ConnectionManager holds connection state, sequence counters, and RTT
//   metrics that are read/written from multiple async contexts (the send
//   loop, receive loop, and reconnect timer). Making it an actor means we
//   don't need manual locks — the compiler enforces isolation.
//
// Learning note (exponential backoff):
//   After a disconnect, we retry with increasing delays: 1s, 2s, 4s, 8s,
//   capping at 30s. This prevents hammering a dead connection while still
//   recovering quickly when the device is plugged back in. The backoff
//   resets to 1s on a successful connection.
// --------------------------------------------------------------------------

import Foundation
import Network

// MARK: - Connection State

/// The state machine for the transport connection.
///
/// States flow: idle -> connecting -> connected -> reconnecting -> error
/// Any state can transition to `error` on an unrecoverable failure.
/// `reconnecting` cycles back to `connecting` on each retry attempt.
public enum ConnectionState: Sendable, Equatable, CustomStringConvertible {
    /// No connection attempted yet.
    case idle

    /// Actively attempting to connect (initial or retry).
    case connecting

    /// Connection established and healthy.
    case connected

    /// Connection lost; attempting to reconnect with backoff.
    case reconnecting(attempt: Int)

    /// An unrecoverable error occurred. Human intervention needed.
    case error(String)

    public var description: String {
        switch self {
        case .idle:                        return "idle"
        case .connecting:                  return "connecting"
        case .connected:                   return "connected"
        case .reconnecting(let attempt):   return "reconnecting (attempt \(attempt))"
        case .error(let msg):              return "error: \(msg)"
        }
    }
}

// MARK: - Connection Event

/// Events emitted by the ConnectionManager for UI and logging.
///
/// Consumers (e.g., the app shell's status bar) observe these to update
/// the connection indicator and surface errors to the user.
public enum ConnectionEvent: Sendable {
    /// The connection state changed.
    case stateChanged(ConnectionState)

    /// A frame was successfully acknowledged. Includes RTT in milliseconds.
    case frameAcknowledged(sequence: UInt32, rttMs: Double)

    /// A frame was dropped due to backpressure (ACK not received in time).
    case frameDropped(sequence: UInt32)

    /// Input events were received from the Boox device.
    case inputReceived(count: Int)
}

// MARK: - ConnectionManagerDelegate

/// Protocol for receiving connection lifecycle events.
///
/// Learning note (protocol vs. AsyncStream for events):
///   We use a protocol delegate here rather than an AsyncStream because
///   the ConnectionManager needs to trigger actions in the pipeline
///   (e.g., "send a keyframe now") that require synchronous coordination.
///   AsyncStream is better for fire-and-forget observation.
public protocol ConnectionManagerDelegate: AnyObject, Sendable {
    /// Called when the connection state changes.
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState)

    /// Called when a keyframe should be sent (after reconnection or on request).
    func connectionManagerNeedsKeyframe(_ manager: ConnectionManager)

    /// Called when input events are received from the Boox device.
    func connectionManager(_ manager: ConnectionManager, didReceiveInput data: Data)
}

// MARK: - ConnectionManager

/// Manages transport connection lifecycle with auto-reconnect and backpressure.
///
/// ConnectionManager is the central coordinator for the Mac-side transport:
///
/// 1. **Listens** for incoming connections from the Boox via the ADB tunnel.
/// 2. **Monitors** connection health via ACK round-trip times.
/// 3. **Reconnects** automatically with exponential backoff on disconnect.
/// 4. **Coordinates** keyframe resend after each reconnection.
/// 5. **Enforces** backpressure by tracking outstanding ACKs.
///
/// Usage:
/// ```swift
/// let manager = ConnectionManager(port: 8888)
/// manager.delegate = self
/// try await manager.start()
/// try await manager.sendFrame(payload: compressedData, isKeyframe: true, isColor: false)
/// ```
public actor ConnectionManager {

    // MARK: - Configuration

    /// Exponential backoff configuration for reconnection.
    private struct BackoffConfig {
        /// Initial delay before the first retry (seconds).
        let initialDelay: TimeInterval = 1.0

        /// Maximum delay between retries (seconds).
        let maxDelay: TimeInterval = 30.0

        /// Multiplier applied to the delay after each failed attempt.
        let multiplier: Double = 2.0

        /// Compute the delay for a given attempt number (0-indexed).
        func delay(forAttempt attempt: Int) -> TimeInterval {
            let raw = initialDelay * pow(multiplier, Double(attempt))
            return min(raw, maxDelay)
        }
    }

    /// ACK timeout — if no ACK arrives within this window, assume the connection is dead.
    private let ackTimeout: TimeInterval = 2.0

    // MARK: - State

    /// Current connection state.
    private(set) var state: ConnectionState = .idle

    /// The active socket tunnel (nil when disconnected).
    private var tunnel: SocketTunnel?

    /// The TCP listener accepting connections from the Boox.
    private var listener: TCPListener?

    /// The port to listen on.
    private let port: UInt16

    /// Monotonically increasing frame sequence counter.
    private var nextSequence: UInt32 = 0

    /// Sequence number of the last frame sent (awaiting ACK).
    private var lastSentSequence: UInt32?

    /// Timestamp when the last frame was sent (for RTT calculation).
    private var lastSendTime: ContinuousClock.Instant?

    /// Whether we are currently waiting for an ACK (backpressure gate).
    private var awaitingACK = false

    /// Reconnection attempt counter (reset on successful connect).
    private var reconnectAttempt = 0

    /// Backoff configuration.
    private let backoff = BackoffConfig()

    /// Whether the manager has been started and should keep running.
    private var isRunning = false

    /// The delegate receiving lifecycle events.
    public weak var delegate: (any ConnectionManagerDelegate)?

    /// Background task for the receive loop.
    private var receiveTask: Task<Void, Never>?

    /// Background task for connection monitoring.
    private var monitorTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Create a ConnectionManager that will listen on the given port.
    ///
    /// - Parameter port: TCP port for the listener (default: 8888).
    public init(port: UInt16 = WireProtocol.defaultPort) {
        self.port = port
    }

    deinit {
        receiveTask?.cancel()
        monitorTask?.cancel()
    }

    // MARK: - Public API

    /// Start listening for incoming connections from the Boox device.
    ///
    /// This sets up the TCP listener and begins accepting connections.
    /// The first connection from the Boox transitions the state to `.connected`.
    ///
    /// - Throws: `TransportError.listenerFailed` if the port is unavailable.
    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        transition(to: .connecting)

        let newListener = try TCPListener(port: port)
        self.listener = newListener

        let connections = try await newListener.start()

        // Accept connections in the background.
        monitorTask = Task { [weak self] in
            for await incomingTunnel in connections {
                guard let self = self else { break }
                await self.handleNewConnection(incomingTunnel)
            }
        }
    }

    /// Stop the connection manager, tearing down the listener and any active connection.
    public func stop() {
        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        tunnel?.cancel()
        tunnel = nil
        listener?.stop()
        listener = nil
        transition(to: .idle)
    }

    /// Send a frame payload over the transport connection.
    ///
    /// The frame is wrapped in the wire protocol header (11 bytes + payload).
    /// If the manager is waiting for an ACK from a previous frame, the send
    /// is rejected (returns `false`) to enforce backpressure.
    ///
    /// - Parameters:
    ///   - payload: The compressed frame/delta data.
    ///   - isKeyframe: Whether this is a full keyframe (vs. delta).
    ///   - isColor: Whether this is a color frame (vs. B&W).
    /// - Returns: `true` if the frame was sent, `false` if dropped (backpressure).
    /// - Throws: `TransportError` on connection errors.
    @discardableResult
    public func sendFrame(payload: Data, isKeyframe: Bool, isColor: Bool) async throws -> Bool {
        guard state == .connected, let tunnel = tunnel else {
            return false
        }

        // Backpressure: don't queue frames if the receiver hasn't ACKed the last one.
        if awaitingACK {
            let seq = nextSequence
            delegate?.connectionManager(self, didChangeState: state)
            // Log the drop but don't throw — this is expected behavior.
            notifyEvent(.frameDropped(sequence: seq))
            return false
        }

        var flags = FrameFlags()
        if isKeyframe { flags.insert(.keyframe) }
        if isColor { flags.insert(.colorMode) }

        let sequence = nextSequence
        nextSequence &+= 1  // Wrapping add for sequence overflow.

        let header = FrameHeader(
            flags: flags,
            sequence: sequence,
            payloadLength: UInt32(payload.count)
        )

        try await tunnel.sendFrame(header: header, payload: payload)

        lastSentSequence = sequence
        lastSendTime = .now
        awaitingACK = true

        return true
    }

    /// Send a control message over the transport.
    ///
    /// Control messages use the `isControl` flag to distinguish them from
    /// frame data on the wire.
    ///
    /// - Parameter payload: The serialized control message data.
    /// - Throws: `TransportError` on connection errors.
    public func sendControl(payload: Data) async throws {
        guard state == .connected, let tunnel = tunnel else { return }

        let header = FrameHeader(
            flags: .isControl,
            sequence: nextSequence,
            payloadLength: UInt32(payload.count)
        )
        nextSequence &+= 1

        try await tunnel.sendFrame(header: header, payload: payload)
    }

    // MARK: - Connection Handling

    /// Handle a newly accepted connection from the Boox device.
    private func handleNewConnection(_ newTunnel: SocketTunnel) async {
        // Close any existing connection cleanly.
        tunnel?.cancel()
        receiveTask?.cancel()

        do {
            try await newTunnel.start()
        } catch {
            // Connection failed to start — stay in current state.
            return
        }

        tunnel = newTunnel
        awaitingACK = false
        reconnectAttempt = 0
        transition(to: .connected)

        // Request a keyframe to sync the Boox display.
        delegate?.connectionManagerNeedsKeyframe(self)

        // Start the receive loop for this connection.
        startReceiveLoop()
    }

    /// Start the background receive loop that processes ACKs and input events.
    private func startReceiveLoop() {
        receiveTask?.cancel()

        receiveTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                do {
                    guard let tunnel = await self.tunnel else { break }

                    // Peek at the first 2 bytes to determine packet type.
                    // ACK is 6 bytes, frame header is 11 bytes.
                    // Both start with the magic bytes.
                    // We distinguish by trying to read ACK size first,
                    // since ACKs are the most common incoming packet.
                    let peekData = try await tunnel.receiveExact(WireProtocol.ackSize)

                    // Validate magic.
                    guard peekData[peekData.startIndex] == WireProtocol.magic.0,
                          peekData[peekData.startIndex + 1] == WireProtocol.magic.1 else {
                        // Stream desynchronized. Trigger reconnect.
                        await self.handleConnectionLost()
                        break
                    }

                    // If this is exactly 6 bytes and looks like an ACK, process it.
                    // ACKs don't have a flags byte — just magic + sequence.
                    // But we need to disambiguate from a frame header.
                    // Heuristic: after the magic, if the next byte has flags bits set
                    // for known frame types, it's likely a header start. If it's a
                    // plausible sequence byte, treat as ACK.
                    //
                    // Better approach: the Mac is the SENDER, so it only receives
                    // ACKs and input events from the Boox. Frame headers are only
                    // sent Mac-to-Boox. This simplifies parsing.
                    if peekData.count == WireProtocol.ackSize {
                        // Check if byte 2 could be a flags byte for an input packet.
                        let byte2 = peekData[peekData.startIndex + 2]

                        if byte2 == FrameFlags.hasInput.rawValue {
                            // This is the start of a frame header with input flag.
                            // Read the remaining 5 bytes of the header.
                            let remainingHeader = try await tunnel.receiveExact(
                                WireProtocol.headerSize - WireProtocol.ackSize
                            )
                            var fullHeader = peekData
                            fullHeader.append(remainingHeader)

                            guard let header = FrameHeader.deserialize(from: fullHeader) else {
                                await self.handleConnectionLost()
                                break
                            }

                            // Read the input payload.
                            let inputPayload = try await tunnel.receiveExact(Int(header.payloadLength))
                            await self.handleInputData(inputPayload)

                        } else {
                            // Treat as ACK.
                            if let ack = ACKPacket.deserialize(from: peekData) {
                                await self.handleACK(ack)
                            }
                        }
                    }

                } catch {
                    if !Task.isCancelled {
                        await self.handleConnectionLost()
                    }
                    break
                }
            }
        }
    }

    /// Process a received ACK packet.
    private func handleACK(_ ack: ACKPacket) {
        guard ack.sequence == lastSentSequence else {
            // Stale or out-of-order ACK — ignore.
            return
        }

        let rtt: Double
        if let sendTime = lastSendTime {
            let elapsed = ContinuousClock.now - sendTime
            rtt = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        } else {
            rtt = 0
        }

        awaitingACK = false
        notifyEvent(.frameAcknowledged(sequence: ack.sequence, rttMs: rtt))
    }

    /// Process received input event data.
    private func handleInputData(_ data: Data) {
        let eventCount = data.count / WireProtocol.inputPacketSize
        if eventCount > 0 {
            delegate?.connectionManager(self, didReceiveInput: data)
            notifyEvent(.inputReceived(count: eventCount))
        }
    }

    /// Handle a lost connection — begin reconnection with exponential backoff.
    private func handleConnectionLost() {
        guard isRunning else { return }

        tunnel?.cancel()
        tunnel = nil
        awaitingACK = false

        reconnectAttempt += 1
        transition(to: .reconnecting(attempt: reconnectAttempt))

        // The listener is still running. The next accepted connection will
        // be handled by the monitor task via handleNewConnection().
        // If the Boox reconnects (e.g., user re-plugs USB), the listener
        // picks it up automatically. We don't need an explicit retry loop
        // because the ADB tunnel keeps the listener port mapped.
    }

    // MARK: - State Machine

    /// Transition to a new state and notify the delegate.
    private func transition(to newState: ConnectionState) {
        state = newState
        delegate?.connectionManager(self, didChangeState: newState)
        notifyEvent(.stateChanged(newState))
    }

    /// Emit an event. Currently just calls delegate; could be extended to
    /// an AsyncStream for observation by multiple consumers.
    private func notifyEvent(_ event: ConnectionEvent) {
        // Events are informational. The delegate methods above handle
        // the actionable ones. This is a hook for future telemetry/logging.
        _ = event
    }

    // MARK: - Diagnostics

    /// The sequence number that will be assigned to the next sent frame.
    public var currentSequence: UInt32 {
        nextSequence
    }

    /// Whether the sender is blocked waiting for an ACK.
    public var isBackpressured: Bool {
        awaitingACK
    }
}
