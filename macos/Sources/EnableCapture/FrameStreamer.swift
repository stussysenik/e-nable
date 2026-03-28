// --------------------------------------------------------------------------
// FrameStreamer.swift - TCP frame streaming to the Elixir Phoenix server
//
// Connects to the Elixir server's TCP ingress port and sends processed
// frames using the e-nable binary protocol defined in SocketTunnel.swift.
//
// The streamer is an actor (thread-safe by construction) that:
//   1. Opens a TCP connection with TCP_NODELAY via SocketTunnel
//   2. Sends each frame as a FrameHeader + payload pair
//   3. Tracks sequence numbers for flow control
//
// Wire format per frame:
//   [0xDA 0x7E] [flags:1] [seq:4 LE] [len:4 LE] [payload bytes]
//
// Learning note (Swift actors):
//   An actor serializes all access to its mutable state through a
//   cooperative executor. This means `sequence`, `tunnel`, and `isConnected`
//   are never accessed concurrently — no data races, no locks needed.
//   External callers use `await` to enter the actor's isolation domain.
// --------------------------------------------------------------------------

import Foundation
import Network

// MARK: - FrameStreamer

/// Streams processed frames to the Elixir Phoenix server over TCP.
///
/// Uses the existing `SocketTunnel` for low-level framing and the
/// `FrameHeader` / `FrameFlags` types for the wire protocol.
///
/// Usage:
/// ```swift
/// let streamer = FrameStreamer(host: "127.0.0.1", port: 9999)
/// try await streamer.connect()
/// try await streamer.sendFrame(data: greyscaleBytes, isKeyframe: true, isColor: false)
/// streamer.disconnect()
/// ```
public actor FrameStreamer {

    // MARK: - Properties

    /// The underlying TCP tunnel handling raw send/receive.
    private var tunnel: SocketTunnel?

    /// Monotonically increasing sequence number for frame ordering.
    /// The Elixir server uses this for ordering and loss detection.
    private var sequence: UInt32 = 0

    /// Target host for the TCP connection.
    private let host: String

    /// Target port for the TCP connection.
    private let port: UInt16

    /// Whether we currently have an active connection.
    public var isConnected: Bool {
        tunnel != nil
    }

    // MARK: - Init

    /// Create a FrameStreamer targeting the given host and port.
    ///
    /// - Parameters:
    ///   - host: The server hostname or IP (default: localhost).
    ///   - port: The server TCP port (default: 9999, matching Elixir FrameIngress).
    public init(host: String = "127.0.0.1", port: UInt16 = 9999) {
        self.host = host
        self.port = port
    }

    // MARK: - Connection Lifecycle

    /// Open a TCP connection to the Elixir server.
    ///
    /// Creates a SocketTunnel with TCP_NODELAY and waits for the connection
    /// to become ready. Throws TransportError.connectionFailed if the server
    /// is unreachable.
    ///
    /// - Throws: `TransportError.connectionFailed` if the connection cannot be established.
    public func connect() async throws {
        // Tear down any existing connection first.
        if let existing = tunnel {
            existing.cancel()
            self.tunnel = nil
        }

        let newTunnel = SocketTunnel.createClient(host: host, port: port)
        try await newTunnel.start()
        self.tunnel = newTunnel
        self.sequence = 0
    }

    /// Close the TCP connection. Idempotent — safe to call multiple times.
    public func disconnect() {
        tunnel?.cancel()
        tunnel = nil
    }

    // MARK: - Frame Sending

    /// Send a processed frame to the Elixir server.
    ///
    /// Builds a FrameHeader with the appropriate flags and current sequence
    /// number, then sends header + payload as a single atomic write via
    /// SocketTunnel.sendFrame().
    ///
    /// - Parameters:
    ///   - data: The frame payload (greyscale pixels, compressed data, etc.).
    ///   - isKeyframe: True if this is a full frame (not a delta). The server
    ///     uses this to decide whether to store the frame for late-joining viewers.
    ///   - isColor: True if the payload contains color data (vs. greyscale).
    /// - Throws: `TransportError.sendFailed` if the write fails, or
    ///           `StreamerError.notConnected` if `connect()` hasn't been called.
    public func sendFrame(data: Data, isKeyframe: Bool, isColor: Bool) async throws {
        guard let tunnel = tunnel else {
            throw StreamerError.notConnected
        }

        // Build flags from the boolean parameters.
        var flags: FrameFlags = []
        if isKeyframe { flags.insert(.keyframe) }
        if isColor { flags.insert(.colorMode) }

        let header = FrameHeader(
            flags: flags,
            sequence: sequence,
            payloadLength: UInt32(data.count)
        )

        try await tunnel.sendFrame(header: header, payload: data)

        // Increment sequence after successful send.
        sequence &+= 1
    }

    /// The current sequence number (frames sent so far).
    ///
    /// Useful for logging and diagnostics — lets the CLI report how many
    /// frames have been streamed to the server.
    public var framesSent: UInt32 {
        sequence
    }
}

// MARK: - StreamerError

/// Errors specific to the FrameStreamer layer (above SocketTunnel).
public enum StreamerError: LocalizedError, Sendable {
    /// Attempted to send a frame before calling connect().
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "FrameStreamer is not connected. Call connect() first."
        }
    }
}
