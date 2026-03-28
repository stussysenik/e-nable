// --------------------------------------------------------------------------
// SocketTunnel.swift - Binary protocol framing over Network.framework
//
// Implements the wire protocol defined in design.md Section 5. Handles
// serialization/deserialization of frame headers, ACK packets, and input
// event packets over a TCP connection using Apple's Network.framework.
//
// Protocol summary:
//   Header (11 bytes): [magic 2B] [flags 1B] [sequence 4B LE] [length 4B LE]
//   ACK    (6 bytes):  [magic 2B] [sequence 4B LE]
//   Input  (20 bytes): [type 1B] [x 4B] [y 4B] [pressure 2B] [tiltX 2B]
//                      [tiltY 2B] [flags 1B] [timestamp 4B]
//
// Learning note (Network.framework vs. BSD sockets):
//   Network.framework (NWConnection, NWListener) is Apple's modern
//   networking API. It handles TCP state machines, TLS, connection
//   migration, and Wi-Fi Assist automatically. For our use case the key
//   advantage is native async/await integration via receive() and send()
//   completion handlers, plus built-in TCP_NODELAY via NWProtocolTCP.Options.
//
// Learning note (little-endian encoding):
//   The wire protocol uses little-endian for multi-byte integers. Swift's
//   .littleEndian property on integer types handles byte swapping on
//   big-endian architectures (though all Apple Silicon is little-endian,
//   being explicit is correct practice).
// --------------------------------------------------------------------------

import Foundation
import Network

// MARK: - Protocol Constants

/// Wire protocol constants shared across the transport layer.
///
/// These values define the binary framing format. Both the Mac sender
/// and the Boox receiver must agree on these exactly.
public enum WireProtocol {

    /// Magic bytes that prefix every header and ACK packet.
    /// Used for frame synchronization — if the receiver sees bytes that
    /// don't start with this magic, it knows the stream is misaligned.
    public static let magic: (UInt8, UInt8) = (0xDA, 0x7E)

    /// Size of a frame header in bytes: magic(2) + flags(1) + sequence(4) + length(4).
    public static let headerSize = 11

    /// Size of an ACK packet in bytes: magic(2) + sequence(4).
    public static let ackSize = 6

    /// Size of a single input event packet in bytes.
    public static let inputPacketSize = 20

    /// Default TCP port for the transport tunnel.
    public static let defaultPort: UInt16 = 8888

    /// Maximum payload size (16 MB). Frames exceeding this are rejected
    /// to prevent memory exhaustion from corrupt length fields.
    public static let maxPayloadSize: UInt32 = 16 * 1024 * 1024
}

// MARK: - Frame Flags

/// Bit flags in the frame header's flags byte.
///
/// Learning note (OptionSet):
///   Swift's OptionSet is the idiomatic way to represent bitfield flags.
///   It provides set algebra operations (contains, union, intersection)
///   while storing the raw value as a single integer — perfect for a
///   wire protocol flags byte.
public struct FrameFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Bit 0: Payload is a full keyframe (not a delta).
    public static let keyframe    = FrameFlags(rawValue: 1 << 0)

    /// Bit 1: Payload uses color mode (not B&W).
    public static let colorMode   = FrameFlags(rawValue: 1 << 1)

    /// Bit 2: Payload contains input events.
    public static let hasInput    = FrameFlags(rawValue: 1 << 2)

    /// Bit 3: Payload is a control message.
    public static let isControl   = FrameFlags(rawValue: 1 << 3)
}

// MARK: - Frame Header

/// An 11-byte frame header parsed from or serialized to the wire.
///
/// ```
/// +--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+
/// | 0xDA   | 0x7E   | flags  | seq[0] | seq[1] | seq[2] | seq[3] | len[0] | len[1] | len[2] | len[3] |
/// +--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+
///   magic (2B)       flags(1B)  sequence (4B LE)                    length (4B LE)
/// ```
public struct FrameHeader: Sendable, Equatable {
    public var flags: FrameFlags
    public var sequence: UInt32
    public var payloadLength: UInt32

    public init(flags: FrameFlags, sequence: UInt32, payloadLength: UInt32) {
        self.flags = flags
        self.sequence = sequence
        self.payloadLength = payloadLength
    }

    /// Serialize this header into exactly 11 bytes (little-endian).
    public func serialize() -> Data {
        var data = Data(capacity: WireProtocol.headerSize)
        data.append(WireProtocol.magic.0)
        data.append(WireProtocol.magic.1)
        data.append(flags.rawValue)

        // Sequence number — 4 bytes, little-endian.
        var seqLE = sequence.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &seqLE) { Array($0) })

        // Payload length — 4 bytes, little-endian.
        var lenLE = payloadLength.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &lenLE) { Array($0) })

        return data
    }

    /// Deserialize an 11-byte buffer into a FrameHeader.
    ///
    /// - Parameter data: Exactly 11 bytes of header data.
    /// - Returns: The parsed header, or `nil` if magic doesn't match or data is too short.
    public static func deserialize(from data: Data) -> FrameHeader? {
        guard data.count >= WireProtocol.headerSize else { return nil }

        // Validate magic bytes.
        guard data[data.startIndex] == WireProtocol.magic.0,
              data[data.startIndex + 1] == WireProtocol.magic.1 else {
            return nil
        }

        let flags = FrameFlags(rawValue: data[data.startIndex + 2])

        // Read sequence (4 bytes LE starting at offset 3).
        let sequence: UInt32 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 3, as: UInt32.self)
            return UInt32(littleEndian: raw)
        }

        // Read payload length (4 bytes LE starting at offset 7).
        let payloadLength: UInt32 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 7, as: UInt32.self)
            return UInt32(littleEndian: raw)
        }

        return FrameHeader(flags: flags, sequence: sequence, payloadLength: payloadLength)
    }
}

// MARK: - ACK Packet

/// A 6-byte acknowledgment packet sent by the receiver after processing a frame.
///
/// ACKs serve two purposes:
/// 1. **Flow control** — the sender waits for an ACK before pushing the next frame,
///    naturally rate-limiting to the e-ink display's refresh speed.
/// 2. **RTT tracking** — the sender timestamps each send and measures round-trip
///    time from the ACK arrival.
///
/// ```
/// +--------+--------+--------+--------+--------+--------+
/// | 0xDA   | 0x7E   | seq[0] | seq[1] | seq[2] | seq[3] |
/// +--------+--------+--------+--------+--------+--------+
///   magic (2B)        sequence (4B LE)
/// ```
public struct ACKPacket: Sendable, Equatable {
    public var sequence: UInt32

    public init(sequence: UInt32) {
        self.sequence = sequence
    }

    /// Serialize into 6 bytes.
    public func serialize() -> Data {
        var data = Data(capacity: WireProtocol.ackSize)
        data.append(WireProtocol.magic.0)
        data.append(WireProtocol.magic.1)

        var seqLE = sequence.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &seqLE) { Array($0) })

        return data
    }

    /// Deserialize a 6-byte buffer into an ACKPacket.
    ///
    /// - Parameter data: Exactly 6 bytes.
    /// - Returns: The parsed ACK, or `nil` if magic doesn't match or data is too short.
    public static func deserialize(from data: Data) -> ACKPacket? {
        guard data.count >= WireProtocol.ackSize else { return nil }

        guard data[data.startIndex] == WireProtocol.magic.0,
              data[data.startIndex + 1] == WireProtocol.magic.1 else {
            return nil
        }

        let sequence: UInt32 = data.withUnsafeBytes { buffer in
            let raw = buffer.load(fromByteOffset: 2, as: UInt32.self)
            return UInt32(littleEndian: raw)
        }

        return ACKPacket(sequence: sequence)
    }
}

// MARK: - Transport Errors

/// Errors specific to the socket transport layer.
public enum TransportError: LocalizedError, Sendable {
    /// TCP connection could not be established.
    case connectionFailed(String)

    /// The connection was lost unexpectedly.
    case connectionLost

    /// A received packet has invalid magic bytes (stream desynchronized).
    case invalidMagic

    /// A received payload length exceeds the maximum allowed size.
    case payloadTooLarge(UInt32)

    /// ACK was not received within the expected timeout window.
    case ackTimeout

    /// The listener could not be started on the requested port.
    case listenerFailed(String)

    /// A send operation failed.
    case sendFailed(String)

    /// A receive operation failed.
    case receiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg):
            return "Transport connection failed: \(msg)"
        case .connectionLost:
            return "Transport connection lost."
        case .invalidMagic:
            return "Invalid magic bytes in received packet — stream may be desynchronized."
        case .payloadTooLarge(let size):
            return "Payload size \(size) exceeds maximum \(WireProtocol.maxPayloadSize)."
        case .ackTimeout:
            return "ACK timeout — receiver did not acknowledge frame within deadline."
        case .listenerFailed(let msg):
            return "TCP listener failed: \(msg)"
        case .sendFailed(let msg):
            return "Send failed: \(msg)"
        case .receiveFailed(let msg):
            return "Receive failed: \(msg)"
        }
    }
}

// MARK: - SocketTunnel

/// Manages a single TCP connection for the e-nable wire protocol.
///
/// SocketTunnel handles the low-level send/receive of framed data over
/// a Network.framework NWConnection. It provides:
/// - Sending frame headers + payloads as atomic units
/// - Receiving and parsing frame headers, ACK packets, and input events
/// - TCP_NODELAY configuration for low-latency delivery
///
/// This class does NOT manage connection lifecycle (connect/reconnect/backoff).
/// That responsibility belongs to `ConnectionManager`.
///
/// Learning note (NWConnection send/receive):
///   NWConnection.send() and receive() use completion handlers, not
///   async/await natively. We bridge to Swift concurrency using
///   withCheckedThrowingContinuation. Each send/receive call must
///   complete before the next one starts on the same connection —
///   Network.framework serializes operations internally, but our
///   continuations must be resumed exactly once.
public final class SocketTunnel: @unchecked Sendable {

    /// The underlying Network.framework connection.
    private let connection: NWConnection

    /// Queue for NWConnection callbacks. Dedicated serial queue avoids
    /// contention with the main queue.
    private let queue: DispatchQueue

    /// Create a SocketTunnel wrapping an existing NWConnection.
    ///
    /// - Parameter connection: An NWConnection in any state. The caller is
    ///   responsible for starting the connection before calling send/receive.
    public init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.enable.transport.socket", qos: .userInteractive)
    }

    /// Create a new outbound TCP connection with TCP_NODELAY enabled.
    ///
    /// - Parameters:
    ///   - host: The target hostname or IP address.
    ///   - port: The target TCP port.
    /// - Returns: A SocketTunnel ready to be started via `start()`.
    public static func createClient(host: String, port: UInt16) -> SocketTunnel {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true  // Critical for low-latency small packet delivery.

        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)

        return SocketTunnel(connection: connection)
    }

    /// Start the connection and wait for it to become ready.
    ///
    /// - Throws: `TransportError.connectionFailed` if the connection enters
    ///   a failed or cancelled state before becoming ready.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            connection.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }

                switch state {
                case .ready:
                    resumed = true
                    // Clear the handler to avoid retain cycles.
                    self?.connection.stateUpdateHandler = nil
                    continuation.resume()

                case .failed(let error):
                    resumed = true
                    self?.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: TransportError.connectionFailed(error.localizedDescription))

                case .cancelled:
                    resumed = true
                    self?.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: TransportError.connectionFailed("Connection cancelled"))

                default:
                    break  // .setup, .preparing, .waiting — keep waiting.
                }
            }

            connection.start(queue: queue)
        }
    }

    /// Cancel the underlying connection. Idempotent.
    public func cancel() {
        connection.cancel()
    }

    // MARK: - Sending

    /// Send a framed message: header (11 bytes) followed by the payload.
    ///
    /// Both the header and payload are sent as a single TCP write to minimize
    /// system call overhead and ensure they arrive in one segment when possible.
    ///
    /// - Parameters:
    ///   - header: The frame header describing the payload.
    ///   - payload: The payload data (compressed frame, control message, etc.).
    /// - Throws: `TransportError.sendFailed` on write errors.
    public func sendFrame(header: FrameHeader, payload: Data) async throws {
        var message = header.serialize()
        message.append(payload)
        try await sendRaw(message)
    }

    /// Send an ACK packet (6 bytes) for the given sequence number.
    ///
    /// - Parameter sequence: The sequence number being acknowledged.
    /// - Throws: `TransportError.sendFailed` on write errors.
    public func sendACK(sequence: UInt32) async throws {
        let ack = ACKPacket(sequence: sequence)
        try await sendRaw(ack.serialize())
    }

    /// Send raw bytes over the connection.
    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: TransportError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Receiving

    /// Receive exactly `length` bytes from the connection.
    ///
    /// This blocks (in async terms) until all requested bytes arrive or
    /// the connection fails. Network.framework coalesces reads internally,
    /// so this maps to `receive(minimumIncompleteLength: length, maximumLength: length)`.
    ///
    /// - Parameter length: The exact number of bytes to read.
    /// - Returns: A Data buffer of exactly `length` bytes.
    /// - Throws: `TransportError.receiveFailed` or `TransportError.connectionLost`.
    public func receiveExact(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: TransportError.receiveFailed(error.localizedDescription))
                    return
                }

                if isComplete && (content == nil || content!.count < length) {
                    continuation.resume(throwing: TransportError.connectionLost)
                    return
                }

                guard let data = content, data.count == length else {
                    continuation.resume(throwing: TransportError.receiveFailed(
                        "Expected \(length) bytes, got \(content?.count ?? 0)"
                    ))
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    /// Receive and parse a frame header (11 bytes).
    ///
    /// - Returns: The deserialized `FrameHeader`.
    /// - Throws: `TransportError` on connection or parsing errors.
    public func receiveHeader() async throws -> FrameHeader {
        let data = try await receiveExact(WireProtocol.headerSize)

        guard let header = FrameHeader.deserialize(from: data) else {
            throw TransportError.invalidMagic
        }

        guard header.payloadLength <= WireProtocol.maxPayloadSize else {
            throw TransportError.payloadTooLarge(header.payloadLength)
        }

        return header
    }

    /// Receive and parse an ACK packet (6 bytes).
    ///
    /// - Returns: The deserialized `ACKPacket`.
    /// - Throws: `TransportError` on connection or parsing errors.
    public func receiveACK() async throws -> ACKPacket {
        let data = try await receiveExact(WireProtocol.ackSize)

        guard let ack = ACKPacket.deserialize(from: data) else {
            throw TransportError.invalidMagic
        }

        return ack
    }

    /// Receive a complete framed message: header + payload.
    ///
    /// - Returns: A tuple of the header and the raw payload data.
    /// - Throws: `TransportError` on connection or parsing errors.
    public func receiveFrame() async throws -> (header: FrameHeader, payload: Data) {
        let header = try await receiveHeader()
        let payload = try await receiveExact(Int(header.payloadLength))
        return (header, payload)
    }

    // MARK: - Connection State

    /// The current state of the underlying NWConnection.
    public var state: NWConnection.State {
        connection.state
    }

    /// The underlying NWConnection, exposed for advanced use cases
    /// (e.g., installing a custom state update handler).
    public var rawConnection: NWConnection {
        connection
    }
}

// MARK: - TCP Listener

/// A TCP listener that accepts incoming connections on a given port.
///
/// Used on the Mac side to accept the Boox client's connection through
/// the ADB reverse tunnel. The Boox connects to localhost:<port> on
/// the device, which ADB tunnels to this listener on the Mac.
///
/// Learning note (NWListener):
///   NWListener is Network.framework's server-side abstraction. It binds
///   to a port, handles TCP accept internally, and delivers new connections
///   through a handler callback. We wrap this in an AsyncStream for
///   clean consumption in async code.
public final class TCPListener: @unchecked Sendable {

    private let listener: NWListener
    private let queue: DispatchQueue

    /// Create a TCP listener on the specified port with TCP_NODELAY.
    ///
    /// - Parameter port: The TCP port to listen on (default 8888).
    /// - Throws: `TransportError.listenerFailed` if the listener can't be created.
    public init(port: UInt16 = WireProtocol.defaultPort) throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)

        // Allow port reuse so we can restart quickly after a crash.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        do {
            listener = try NWListener(using: params)
        } catch {
            throw TransportError.listenerFailed(error.localizedDescription)
        }

        queue = DispatchQueue(label: "com.enable.transport.listener", qos: .userInteractive)
    }

    /// Start the listener and return an AsyncStream of accepted connections.
    ///
    /// Each yielded `SocketTunnel` wraps a newly accepted NWConnection
    /// that is already configured with TCP_NODELAY. The caller must call
    /// `start()` on the SocketTunnel before sending or receiving.
    ///
    /// - Returns: An `AsyncStream<SocketTunnel>` that yields connections as they arrive.
    /// - Throws: `TransportError.listenerFailed` if the listener cannot start.
    public func start() async throws -> AsyncStream<SocketTunnel> {
        let stream = AsyncStream<SocketTunnel> { continuation in
            listener.newConnectionHandler = { newConnection in
                let tunnel = SocketTunnel(connection: newConnection)
                continuation.yield(tunnel)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    continuation.finish()
                default:
                    break
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.listener.cancel()
            }
        }

        listener.start(queue: queue)

        // Wait briefly to detect immediate binding failures.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // We use a small delay to give the listener time to report errors.
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TransportError.listenerFailed("Listener deallocated"))
                    return
                }

                switch self.listener.state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: TransportError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: TransportError.listenerFailed("Listener cancelled"))
                default:
                    // Still starting — assume it will succeed.
                    continuation.resume()
                }
            }
        }

        return stream
    }

    /// Stop the listener and reject any pending connections.
    public func stop() {
        listener.cancel()
    }

    /// The port the listener is bound to. Available after `start()`.
    public var port: UInt16? {
        listener.port?.rawValue
    }
}
