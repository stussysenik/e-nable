/**
 * Protocol.kt — Binary Wire Protocol for e-nable Screen Mirroring
 *
 * # What this file defines
 *
 * Constants, data classes, and parser/serializer functions for the binary
 * protocol that flows between the Mac (sender) and Boox (receiver) over
 * a TCP socket tunneled through ADB USB-C.
 *
 * # Protocol overview
 *
 * The protocol is deliberately simple — no TLS, no HTTP, no protobuf.
 * It's a length-prefixed binary protocol optimized for:
 *   - Minimal overhead: 11-byte header vs. ~40 bytes for HTTP/2
 *   - Zero-copy parsing: read directly into pre-allocated ByteBuffers
 *   - Deterministic latency: no variable-length field negotiation
 *
 * Every message has the same header format:
 *
 *   +--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+
 *   | 0xDA   | 0x7E   | Flags  | Sequence (4B LE)                  | Length (4B LE)                    |
 *   +--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+--------+
 *     magic    magic    1 byte   frame counter                       payload byte count
 *
 * ACK responses are 6 bytes: magic (2B) + sequence (4B LE).
 *
 * Input packets are 20 bytes: type (1B) + x (4B float) + y (4B float) +
 *   pressure (4B float) + tiltX (4B float) + tiltY (4B float) - NOTE: This is
 *   a simplified encoding; the actual input payload is variable based on the
 *   InputEvent structure from the design doc.
 *
 * # Byte order: Little-Endian
 *
 * All multi-byte integers use little-endian (LE) encoding. This matches:
 *   - ARM64 (Boox SoC): native little-endian
 *   - Apple Silicon (Mac): native little-endian
 *   - x86_64: native little-endian
 *
 * Using native byte order on both endpoints means NO byte-swapping overhead.
 * The Zig core uses @intCast with LE layout, and Java/Kotlin ByteBuffer
 * can be set to ByteOrder.LITTLE_ENDIAN for zero-cost reads.
 *
 * # Why magic bytes?
 *
 * The 0xDA7E magic bytes ("date" in leet-speak) serve as a sync marker.
 * If the TCP stream gets out of sync (partial read, dropped bytes), the
 * receiver scans forward until it finds 0xDA 0x7E, then resumes parsing.
 * This is more robust than assuming every read starts at a header boundary.
 */

package com.enable.mirror

import java.nio.ByteBuffer
import java.nio.ByteOrder

// ============================================================================
// Protocol Constants
// ============================================================================

/**
 * Central registry of all protocol constants.
 *
 * Every magic number, size, and threshold lives here. If you're looking
 * for "where does 11 come from?" or "why 0xDA?", this is the place.
 *
 * These values MUST match the Zig core protocol implementation exactly.
 * A mismatch means the Mac and Boox can't communicate.
 */
object Protocol {

    // -- Magic bytes: identify the start of every packet --
    // 0xDA 0x7E = "DA7E" = "date" — easy to spot in hex dumps
    const val MAGIC_0: Byte = 0xDA.toByte()  // -38 in signed byte (Java quirk)
    const val MAGIC_1: Byte = 0x7E.toByte()  // 126 in signed byte

    // -- Packet sizes --

    /** Frame/control header: magic(2) + flags(1) + sequence(4) + length(4) = 11 bytes */
    const val HEADER_SIZE: Int = 11

    /** ACK response: magic(2) + sequence(4) = 6 bytes */
    const val ACK_SIZE: Int = 6

    /**
     * Input event packet: type(1) + x(4) + y(4) + pressure(4) + tiltX(2) + tiltY(2) + timestamp(8) = 25 bytes
     *
     * Note: The design doc specifies normalized floats for coordinates and pressure,
     * plus f32 radians for tilt. We pack tilt as signed 16-bit fixed-point
     * (radians * 10000) to save 4 bytes per event without losing meaningful precision.
     * At 10000 scale, we get 0.0001 radian resolution (~0.006 degrees) — far beyond
     * what any stylus sensor can actually detect.
     */
    const val INPUT_PACKET_SIZE: Int = 25

    // -- Flag bits (within the flags byte at offset 2) --

    /** Bit 0: keyframe flag. 1 = full frame, 0 = delta frame */
    const val FLAG_KEYFRAME: Int = 0x01

    /** Bit 1: color mode. 1 = Kaleido 3 color, 0 = B&W greyscale */
    const val FLAG_COLOR: Int = 0x02

    /** Bit 2: input data. 1 = payload contains input events */
    const val FLAG_INPUT: Int = 0x04

    /** Bit 3: control message. 1 = payload is a ControlMessage */
    const val FLAG_CONTROL: Int = 0x08

    // -- Thresholds --

    /**
     * Keyframe decision threshold: if more than 60% of pixels changed,
     * send a full frame instead of a delta.
     *
     * Why 60%? When most pixels change (e.g., switching apps), the XOR
     * delta buffer has few zeros. RLE/LZ4 compression provides little
     * benefit, and the overhead of dirty region tracking + XOR computation
     * exceeds just sending the raw frame. The 60% threshold was determined
     * empirically in the Zig core benchmarks.
     */
    const val KEYFRAME_THRESHOLD: Float = 0.6f

    // -- Network --

    /** Default TCP port for the ADB reverse tunnel. */
    const val DEFAULT_PORT: Int = 8888

    /**
     * ACK timeout in milliseconds. If no ACK arrives within this window,
     * the connection is considered lost. 2000ms provides generous headroom:
     * - E-ink GC refresh takes ~600ms
     * - Worst-case LZ4 decompression: ~5ms
     * - USB-C round trip: ~2ms
     * - Total worst case: ~607ms
     * 2000ms gives 3x safety margin.
     */
    const val ACK_TIMEOUT_MS: Long = 2000

    /**
     * Reconnect backoff schedule. Exponential backoff starting at 100ms,
     * doubling each attempt, capped at 5000ms.
     */
    const val RECONNECT_BASE_MS: Long = 100
    const val RECONNECT_MAX_MS: Long = 5000

    /**
     * Ghost clear interval: force a GC refresh every N frames to clear
     * e-ink ghosting artifacts. 30 is a good default — roughly every
     * 6-18 seconds depending on refresh mode (DW=5fps, GU=1.7fps).
     * Configurable via ControlMessage.
     */
    const val DEFAULT_GHOST_CLEAR_INTERVAL: Int = 30
}

// ============================================================================
// Data Classes — Protocol Messages
// ============================================================================

/**
 * Parsed frame header from an incoming packet.
 *
 * This is a VALUE class — cheap to create, no heap allocation on most
 * JVMs (Kotlin value classes inline the fields). We parse every incoming
 * packet into a FrameHeader first, then dispatch based on flags.
 *
 * @property flags    Raw flags byte. Use the FLAG_* constants and
 *                    extension properties below to interpret bits.
 * @property sequence Monotonically increasing frame number. Used for:
 *                    - ACK correlation (sender matches ACK to frame)
 *                    - Drop detection (gaps in sequence = dropped frames)
 *                    - Keyframe requests (receiver asks for re-send)
 * @property length   Payload byte count (NOT including the 11-byte header).
 *                    The receiver reads exactly this many bytes after the header.
 */
data class FrameHeader(
    val flags: Int,
    val sequence: Long,
    val length: Int
) {
    /** True if this frame is a keyframe (complete frame, not a delta). */
    val isKeyframe: Boolean get() = (flags and Protocol.FLAG_KEYFRAME) != 0

    /** True if the payload uses Kaleido 3 color encoding. */
    val isColor: Boolean get() = (flags and Protocol.FLAG_COLOR) != 0

    /** True if the payload contains input events (Boox -> Mac direction). */
    val isInput: Boolean get() = (flags and Protocol.FLAG_INPUT) != 0

    /** True if the payload is a control message (settings, ping, etc.). */
    val isControl: Boolean get() = (flags and Protocol.FLAG_CONTROL) != 0
}

/**
 * Input event from the Boox stylus/touch digitizer.
 *
 * Coordinates are normalized to [0.0, 1.0] so the Mac side can map them
 * to any virtual display resolution without knowing the Boox's physical
 * screen dimensions.
 *
 * # Why normalized coordinates?
 *
 * The Boox Note Air 3 C has a 1240x930 e-ink display, but the Mac's
 * virtual display might be at a different resolution (e.g., Retina 2x).
 * Normalizing on the Boox side and denormalizing on the Mac side
 * decouples the two resolutions completely.
 *
 * @property type     Event type (down/move/up for stylus or touch)
 * @property x        Horizontal position, 0.0 = left edge, 1.0 = right edge
 * @property y        Vertical position, 0.0 = top edge, 1.0 = bottom edge
 * @property pressure Stylus pressure, 0.0 = no pressure, 1.0 = max pressure.
 *                    The Boox Wacom EMR digitizer provides 4096 pressure levels,
 *                    mapped to float for resolution independence.
 * @property tiltX    Stylus tilt in the X axis, radians (-PI/2 to PI/2)
 * @property tiltY    Stylus tilt in the Y axis, radians (-PI/2 to PI/2)
 */
data class InputEvent(
    val type: InputType,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
    val timestampNs: Long
)

/**
 * Input event types. Maps to the design doc's InputEvent.type enum.
 *
 * Stylus events come from the Wacom EMR digitizer (electromagnetic resonance).
 * Touch events come from the capacitive touch layer above the e-ink panel.
 * They are independent sensor systems — you can have stylus input while
 * touching the screen (palm rejection uses this).
 */
enum class InputType(val wire: Byte) {
    /** Stylus tip touched the screen (pen down) */
    STYLUS_DOWN(0),

    /** Stylus moved while touching (drawing/writing) */
    STYLUS_MOVE(1),

    /** Stylus lifted from screen (pen up) */
    STYLUS_UP(2),

    /** Finger touched the screen */
    TOUCH_DOWN(3),

    /** Finger moved while touching (scrolling/dragging) */
    TOUCH_MOVE(4),

    /** Finger lifted from screen */
    TOUCH_UP(5);

    companion object {
        /**
         * Look up InputType by wire byte value.
         *
         * Uses a pre-built array for O(1) lookup instead of iterating
         * the enum values on every input event (which would be O(n)).
         * At 120Hz touch sampling, this saves ~600 unnecessary comparisons
         * per second.
         */
        private val byWire = values().associateBy { it.wire }
        fun fromWire(b: Byte): InputType? = byWire[b]
    }
}

/**
 * Dirty rectangle — a region of the screen that changed between frames.
 *
 * The renderer only needs to refresh these areas on the e-ink display,
 * not the entire screen. For a cursor blink, this might be a tiny 16x16
 * rect instead of the full 1240x930 display — saving ~600ms of GC refresh
 * time by using a fast DW partial refresh instead.
 *
 * @property x      Left edge in pixels
 * @property y      Top edge in pixels
 * @property width  Width in pixels
 * @property height Height in pixels
 */
data class DirtyRect(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int
)

// ============================================================================
// Parser Functions — Byte Stream -> Data Classes
// ============================================================================

/**
 * Parse an 11-byte header from a ByteBuffer.
 *
 * # ByteBuffer position contract
 *
 * This function reads exactly [Protocol.HEADER_SIZE] bytes starting at the
 * buffer's current position. After return, the position is advanced by 11.
 * The caller is responsible for ensuring at least 11 bytes are available.
 *
 * # Error handling
 *
 * Returns null if the magic bytes don't match. This is NOT an error in the
 * traditional sense — it means the stream is out of sync and the caller
 * should scan forward to find the next valid header.
 *
 * @param buffer ByteBuffer with at least 11 bytes remaining, set to LITTLE_ENDIAN
 * @return Parsed FrameHeader, or null if magic bytes don't match
 */
fun parseHeader(buffer: ByteBuffer): FrameHeader? {
    // Ensure little-endian byte order for multi-byte reads.
    // ByteBuffer defaults to BIG_ENDIAN (network byte order),
    // but our protocol uses LITTLE_ENDIAN (native ARM/x86 order).
    buffer.order(ByteOrder.LITTLE_ENDIAN)

    // -- Validate magic bytes --
    // These must be 0xDA 0x7E. If not, the stream is misaligned.
    val magic0 = buffer.get()
    val magic1 = buffer.get()
    if (magic0 != Protocol.MAGIC_0 || magic1 != Protocol.MAGIC_1) {
        return null
    }

    // -- Parse flags (1 byte) --
    // Read as unsigned: Kotlin Byte is signed (-128..127), but flags
    // are logically unsigned (0..255). The `and 0xFF` converts to int
    // without sign extension.
    val flags = buffer.get().toInt() and 0xFF

    // -- Parse sequence number (4 bytes LE) --
    // Read as unsigned 32-bit: Java/Kotlin Int is signed, but sequence
    // numbers are logically unsigned. We store as Long to avoid overflow
    // at 2^31 frames (~16 hours at 15fps — could happen in long sessions).
    val sequence = buffer.getInt().toLong() and 0xFFFFFFFFL

    // -- Parse payload length (4 bytes LE) --
    // This tells us how many bytes to read after the header.
    // Max payload size is limited by Int.MAX_VALUE (~2GB), which is
    // far more than any frame could ever be.
    val length = buffer.getInt()

    return FrameHeader(flags, sequence, length)
}

/**
 * Serialize an ACK packet into a 6-byte ByteBuffer.
 *
 * ACKs are sent by the receiver (Boox) after successfully processing
 * a frame. The sender (Mac) uses them for:
 *   1. Flow control: don't send the next frame until ACK arrives
 *   2. RTT measurement: timestamp delta between send and ACK receipt
 *
 * @param sequence The sequence number being acknowledged (must match
 *                 the received frame's sequence number)
 * @return A 6-byte ByteBuffer ready to write to the socket (position=0, limit=6)
 */
fun buildAck(sequence: Long): ByteBuffer {
    val buffer = ByteBuffer.allocate(Protocol.ACK_SIZE)
    buffer.order(ByteOrder.LITTLE_ENDIAN)

    // Magic bytes
    buffer.put(Protocol.MAGIC_0)
    buffer.put(Protocol.MAGIC_1)

    // Sequence number (truncated to 32 bits for wire format)
    buffer.putInt(sequence.toInt())

    // Flip the buffer for reading: position -> 0, limit -> 6
    // This is a critical step! Without flip(), the buffer's position
    // is at the end (6), and a write to socket would send 0 bytes.
    buffer.flip()
    return buffer
}

/**
 * Serialize an input event into a ByteBuffer for transmission.
 *
 * The Mac side receives these and converts them to CGEvent tablet
 * events for cursor control and drawing input.
 *
 * @param event The input event to serialize
 * @return ByteBuffer ready to be wrapped in a protocol frame and sent
 */
fun serializeInputEvent(event: InputEvent): ByteBuffer {
    val buffer = ByteBuffer.allocate(Protocol.INPUT_PACKET_SIZE)
    buffer.order(ByteOrder.LITTLE_ENDIAN)

    // Event type (1 byte)
    buffer.put(event.type.wire)

    // Normalized coordinates (4 bytes each, IEEE 754 float)
    buffer.putFloat(event.x)
    buffer.putFloat(event.y)

    // Pressure (4 bytes float, 0.0-1.0)
    buffer.putFloat(event.pressure)

    // Tilt as signed 16-bit fixed-point (radians * 10000)
    // This saves 4 bytes vs. two floats while preserving 0.0001 rad precision
    buffer.putShort((event.tiltX * 10000f).toInt().toShort())
    buffer.putShort((event.tiltY * 10000f).toInt().toShort())

    // Timestamp (8 bytes, monotonic nanoseconds)
    buffer.putLong(event.timestampNs)

    buffer.flip()
    return buffer
}

/**
 * Wrap a payload in a full protocol frame (header + payload).
 *
 * This is used to send input events and control messages from the Boox
 * to the Mac. Frame data goes the other direction (Mac -> Boox).
 *
 * @param flags    Protocol flags (use FLAG_INPUT, FLAG_CONTROL, etc.)
 * @param sequence Frame sequence number
 * @param payload  The serialized payload bytes
 * @return ByteBuffer containing the full frame (header + payload), ready to send
 */
fun buildFrame(flags: Int, sequence: Long, payload: ByteArray): ByteBuffer {
    val buffer = ByteBuffer.allocate(Protocol.HEADER_SIZE + payload.size)
    buffer.order(ByteOrder.LITTLE_ENDIAN)

    // Header
    buffer.put(Protocol.MAGIC_0)
    buffer.put(Protocol.MAGIC_1)
    buffer.put(flags.toByte())
    buffer.putInt(sequence.toInt())
    buffer.putInt(payload.size)

    // Payload
    buffer.put(payload)

    buffer.flip()
    return buffer
}
