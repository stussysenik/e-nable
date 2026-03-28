/**
 * ConnectionManager.kt — TCP Socket Connection with Auto-Reconnect
 *
 * # What this class does
 *
 * Manages the TCP connection to the Mac host through an ADB reverse tunnel.
 * Responsibilities:
 *   1. Connect to localhost:8888 (ADB tunnels this to the Mac)
 *   2. Read incoming frame packets (Mac -> Boox)
 *   3. Send ACKs and input events (Boox -> Mac)
 *   4. Detect disconnections and auto-reconnect with exponential backoff
 *
 * # Architecture: Coroutine-based I/O
 *
 * Traditional Android networking uses threads + blocking I/O. We use Kotlin
 * coroutines instead because:
 *   - Coroutines are cancellable (clean shutdown when mirroring stops)
 *   - Structured concurrency prevents leaked connections
 *   - Dispatchers.IO uses a thread pool optimized for blocking I/O
 *   - No manual thread lifecycle management
 *
 * # ADB Reverse Tunnel
 *
 * The Mac runs: `adb reverse tcp:8888 tcp:8888`
 * This creates a tunnel: Boox localhost:8888 -> USB-C -> Mac localhost:8888
 *
 * From the Android app's perspective, it's just connecting to localhost.
 * The ADB daemon handles the USB transport transparently. This is the
 * same mechanism used by Daylight Mirror and other USB mirroring tools.
 *
 * # Flow Control: ACK-Gated Pipeline
 *
 * The Mac sends a frame, then WAITS for an ACK before sending the next.
 * This naturally rate-limits to the e-ink display's refresh speed:
 *   - DW refresh (~200ms): effective ~5 fps
 *   - GU refresh (~600ms): effective ~1.7 fps
 * No frame is ever wasted on a display that can't show it.
 */

package com.enable.mirror

import android.util.Log
import kotlinx.coroutines.*
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Callback interface for connection events.
 *
 * The ConnectionManager is a "dumb pipe" — it reads bytes and sends bytes.
 * It does NOT interpret frame content. The RendererService implements this
 * interface to process frames and render them to the e-ink display.
 *
 * # Why an interface instead of lambdas?
 *
 * An interface groups related callbacks together and makes the contract
 * explicit. With lambdas, it's easy to forget to handle one of the
 * callback types. The interface forces the implementor to handle all cases.
 */
interface ConnectionListener {
    /**
     * Called when a complete frame packet has been received.
     *
     * @param header  Parsed frame header (flags, sequence, length)
     * @param payload Raw payload bytes (compressed frame/delta/control data).
     *                The payload is a NEW ByteArray for each call — the listener
     *                owns it and can hold a reference safely.
     */
    fun onFrameReceived(header: FrameHeader, payload: ByteArray)

    /**
     * Called when the TCP connection is established (or re-established).
     * The listener should request a keyframe since the renderer has no
     * valid previous frame state after (re)connection.
     */
    fun onConnected()

    /**
     * Called when the TCP connection is lost.
     * The listener should show a "reconnecting..." indicator to the user.
     *
     * @param reason Human-readable description of why the connection was lost
     */
    fun onDisconnected(reason: String)
}

/**
 * Manages the TCP connection lifecycle and frame I/O.
 *
 * # Thread safety
 *
 * - [start] and [stop] must be called from the main thread (or a single thread).
 * - [sendAck] and [sendInputEvent] are thread-safe (synchronized on the output stream).
 * - The [ConnectionListener] callbacks are invoked on the IO dispatcher thread,
 *   NOT the main thread. The listener must post to the main thread if it needs
 *   to update UI.
 *
 * # Lifecycle
 *
 * ```
 * val conn = ConnectionManager(listener)
 * conn.start(scope)     // Launches connection coroutine
 * // ... mirroring active ...
 * conn.stop()           // Cancels coroutine, closes socket
 * ```
 *
 * @param listener Callback receiver for connection events
 * @param host     TCP host to connect to (default: localhost via ADB tunnel)
 * @param port     TCP port (default: 8888, matching Protocol.DEFAULT_PORT)
 */
class ConnectionManager(
    private val listener: ConnectionListener,
    private val host: String = "127.0.0.1",
    private val port: Int = Protocol.DEFAULT_PORT
) {
    companion object {
        private const val TAG = "ConnectionManager"
    }

    // -- Connection state --

    /** The active TCP socket, or null if disconnected. */
    @Volatile
    private var socket: Socket? = null

    /** Output stream for sending ACKs and input events. */
    @Volatile
    private var outputStream: OutputStream? = null

    /** Coroutine job for the connection loop. Cancelled on stop(). */
    private var connectionJob: Job? = null

    /** Lock object for thread-safe writes to the output stream. */
    private val writeLock = Any()

    /** True if stop() has been called and we should not reconnect. */
    @Volatile
    private var stopped = false

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /**
     * Start the connection loop.
     *
     * Launches a coroutine that:
     *   1. Connects to the Mac host
     *   2. Reads frames in a loop
     *   3. On disconnect, waits (exponential backoff) and reconnects
     *   4. Repeats until [stop] is called
     *
     * @param scope CoroutineScope that controls the connection lifetime.
     *              Typically tied to the RendererService's lifecycle.
     */
    fun start(scope: CoroutineScope) {
        stopped = false
        connectionJob = scope.launch(Dispatchers.IO) {
            connectionLoop()
        }
    }

    /**
     * Stop the connection loop and close the socket.
     *
     * This is a synchronous call — it cancels the coroutine and closes
     * the socket immediately. The connectionLoop will detect cancellation
     * and exit cleanly.
     */
    fun stop() {
        stopped = true
        connectionJob?.cancel()
        connectionJob = null
        closeSocket()
    }

    // ========================================================================
    // Connection Loop (runs on Dispatchers.IO)
    // ========================================================================

    /**
     * Main connection loop with auto-reconnect.
     *
     * # Exponential backoff
     *
     * After a disconnection, we wait before reconnecting:
     *   Attempt 1: 100ms
     *   Attempt 2: 200ms
     *   Attempt 3: 400ms
     *   Attempt 4: 800ms
     *   ...
     *   Attempt N: min(100 * 2^N, 5000)ms
     *
     * This prevents hammering the connection when the Mac app isn't running
     * or the ADB tunnel isn't set up yet. The backoff resets to 100ms after
     * a successful connection.
     */
    private suspend fun connectionLoop() {
        var backoffMs = Protocol.RECONNECT_BASE_MS

        while (!stopped && currentCoroutineContext().isActive) {
            try {
                // -- Attempt connection --
                Log.i(TAG, "Connecting to $host:$port...")
                val sock = Socket()

                // Connect with a 5-second timeout. This covers the case where
                // ADB tunnel exists but the Mac app isn't listening yet.
                sock.connect(InetSocketAddress(host, port), 5000)

                // TCP_NODELAY disables Nagle's algorithm. Without this,
                // the TCP stack buffers small writes (like 6-byte ACKs) for
                // up to 40ms before sending them, adding latency. With
                // TCP_NODELAY, every write goes out immediately. This is
                // critical for our ACK-gated flow control.
                sock.tcpNoDelay = true

                // SO_KEEPALIVE enables TCP-level keepalive probes.
                // If the USB cable is unplugged, the OS detects the dead
                // connection within ~30 seconds instead of hanging forever.
                sock.keepAlive = true

                // Store references for send methods
                socket = sock
                outputStream = sock.getOutputStream()

                // Reset backoff on successful connection
                backoffMs = Protocol.RECONNECT_BASE_MS

                Log.i(TAG, "Connected to $host:$port")
                listener.onConnected()

                // -- Enter frame reading loop --
                // This blocks until the connection drops or stop() is called
                readLoop(sock.getInputStream())

            } catch (e: CancellationException) {
                // Coroutine was cancelled (stop() called). Don't reconnect.
                Log.i(TAG, "Connection loop cancelled")
                throw e  // Re-throw to exit the coroutine properly

            } catch (e: IOException) {
                // Connection failed or dropped
                Log.w(TAG, "Connection error: ${e.message}")
                closeSocket()
                listener.onDisconnected(e.message ?: "Unknown error")

            } catch (e: Exception) {
                // Unexpected error — log and reconnect anyway
                Log.e(TAG, "Unexpected error in connection loop", e)
                closeSocket()
                listener.onDisconnected(e.message ?: "Unexpected error")
            }

            // -- Backoff before reconnecting --
            if (!stopped && currentCoroutineContext().isActive) {
                Log.i(TAG, "Reconnecting in ${backoffMs}ms...")
                delay(backoffMs)

                // Double the backoff, capped at max
                backoffMs = (backoffMs * 2).coerceAtMost(Protocol.RECONNECT_MAX_MS)
            }
        }
    }

    // ========================================================================
    // Frame Reading Loop
    // ========================================================================

    /**
     * Read frames from the input stream until disconnection.
     *
     * # Zero-copy strategy
     *
     * We pre-allocate a header buffer (11 bytes) and reuse it for every frame.
     * The payload buffer is allocated per-frame because the listener takes
     * ownership (different frames have different sizes, and the renderer may
     * still be processing a previous frame when the next arrives).
     *
     * # Blocking reads on Dispatchers.IO
     *
     * InputStream.read() is a blocking call. That's fine here because:
     *   - We're on Dispatchers.IO, which has a large thread pool for blocking ops
     *   - The coroutine is cancellable: stop() closes the socket, which causes
     *     read() to throw IOException, which exits the loop
     *
     * @param input The TCP socket's input stream
     */
    private suspend fun readLoop(input: InputStream) {
        // Pre-allocate the header buffer — reused for every frame
        val headerBuf = ByteArray(Protocol.HEADER_SIZE)
        val headerByteBuffer = ByteBuffer.wrap(headerBuf)
        headerByteBuffer.order(ByteOrder.LITTLE_ENDIAN)

        while (!stopped && currentCoroutineContext().isActive) {
            // -- Read exactly 11 bytes for the header --
            // readFully() handles the case where read() returns fewer
            // bytes than requested (common with TCP stream boundaries)
            readFully(input, headerBuf)

            // -- Parse the header --
            headerByteBuffer.clear()  // Reset position to 0 for re-reading
            val header = parseHeader(headerByteBuffer)

            if (header == null) {
                // Magic bytes didn't match — stream is out of sync.
                // In a production system, we'd scan forward to find the
                // next valid header. For now, log and continue (the next
                // read may realign).
                Log.w(TAG, "Invalid magic bytes, stream may be out of sync")
                // Try to resync by scanning for magic bytes
                resync(input, headerBuf, headerByteBuffer)
                continue
            }

            // -- Validate payload length --
            // Guard against corrupted length values that could cause OOM
            if (header.length < 0 || header.length > 10_000_000) {
                Log.w(TAG, "Invalid payload length: ${header.length}, skipping")
                continue
            }

            // -- Read the payload --
            val payload = ByteArray(header.length)
            if (header.length > 0) {
                readFully(input, payload)
            }

            // -- Deliver to listener --
            listener.onFrameReceived(header, payload)
        }
    }

    /**
     * Read exactly `buffer.size` bytes from the stream.
     *
     * # Why not just input.read(buffer)?
     *
     * TCP is a STREAM protocol, not a message protocol. A single read()
     * call may return anywhere from 1 byte to buffer.size bytes. For an
     * 11-byte header, you might get 8 bytes on the first read and 3 on
     * the second. This function loops until all bytes are received.
     *
     * This is the same pattern used by java.io.DataInputStream.readFully(),
     * but we avoid DataInputStream because it forces BIG_ENDIAN byte order.
     *
     * @throws IOException if the stream ends before all bytes are read
     *                     (indicates the connection was closed)
     */
    private fun readFully(input: InputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val bytesRead = input.read(buffer, offset, buffer.size - offset)
            if (bytesRead == -1) {
                throw IOException("Connection closed by remote (EOF after $offset/${buffer.size} bytes)")
            }
            offset += bytesRead
        }
    }

    /**
     * Attempt to resynchronize the stream after invalid magic bytes.
     *
     * Scans the input byte-by-byte looking for the magic sequence 0xDA 0x7E.
     * Once found, reads the remaining 9 bytes of the header and processes
     * the frame normally.
     *
     * # Why byte-by-byte?
     *
     * After a sync loss, we don't know where the next valid header starts.
     * It could be at any byte offset. Scanning one byte at a time is slow
     * but correct. Sync loss should be extremely rare (corrupted USB data
     * or a bug in the sender), so this cold path doesn't need optimization.
     *
     * @param input The TCP input stream
     * @param headerBuf Reusable 11-byte header buffer
     * @param headerByteBuffer ByteBuffer wrapper around headerBuf
     */
    private suspend fun resync(
        input: InputStream,
        headerBuf: ByteArray,
        headerByteBuffer: ByteBuffer
    ) {
        Log.w(TAG, "Attempting stream resync — scanning for magic bytes...")
        var scannedBytes = 0
        val maxScan = 1024 * 64  // Don't scan more than 64KB before giving up

        while (scannedBytes < maxScan && !stopped) {
            val b = input.read()
            if (b == -1) throw IOException("EOF during resync")
            scannedBytes++

            // Look for first magic byte
            if (b.toByte() == Protocol.MAGIC_0) {
                val b2 = input.read()
                if (b2 == -1) throw IOException("EOF during resync")
                scannedBytes++

                if (b2.toByte() == Protocol.MAGIC_1) {
                    // Found magic! Read remaining 9 bytes of header
                    Log.i(TAG, "Resync successful after $scannedBytes bytes")
                    headerBuf[0] = Protocol.MAGIC_0
                    headerBuf[1] = Protocol.MAGIC_1
                    readFully(input, ByteArray(9).also {
                        // Read 9 remaining header bytes
                        System.arraycopy(it, 0, headerBuf, 2, 9)
                    })
                    // Let the main loop re-parse this header on the next iteration
                    return
                }
            }
        }

        Log.e(TAG, "Resync failed after scanning $scannedBytes bytes")
    }

    // ========================================================================
    // Send Methods (Thread-Safe)
    // ========================================================================

    /**
     * Send an ACK for a received frame.
     *
     * Called by the RendererService after it finishes processing a frame
     * and updating the e-ink display. The ACK tells the Mac it's safe to
     * send the next frame.
     *
     * # Thread safety
     *
     * Multiple threads could call this simultaneously (e.g., main thread
     * sending ACK while IO thread processes the next header). The writeLock
     * ensures ACK and input packets don't interleave on the wire.
     *
     * @param sequence The sequence number to acknowledge
     * @return true if the ACK was sent successfully, false if the connection is down
     */
    fun sendAck(sequence: Long): Boolean {
        val ackBuffer = buildAck(sequence)
        return writeToSocket(ackBuffer)
    }

    /**
     * Send an input event to the Mac.
     *
     * Wraps the serialized input event in a protocol frame (header + payload)
     * and sends it over the TCP connection.
     *
     * @param event The input event to send
     * @param sequence Current sequence number for the frame header
     * @return true if sent successfully
     */
    fun sendInputEvent(event: InputEvent, sequence: Long): Boolean {
        val eventBuffer = serializeInputEvent(event)
        val payload = ByteArray(eventBuffer.remaining())
        eventBuffer.get(payload)

        val frame = buildFrame(Protocol.FLAG_INPUT, sequence, payload)
        return writeToSocket(frame)
    }

    /**
     * Write a ByteBuffer to the TCP socket.
     *
     * @param buffer Data to send (reads from position to limit)
     * @return true if all bytes were written, false on error
     */
    private fun writeToSocket(buffer: ByteBuffer): Boolean {
        synchronized(writeLock) {
            val out = outputStream ?: return false
            return try {
                val bytes = ByteArray(buffer.remaining())
                buffer.get(bytes)
                out.write(bytes)
                out.flush()
                true
            } catch (e: IOException) {
                Log.w(TAG, "Write failed: ${e.message}")
                false
            }
        }
    }

    // ========================================================================
    // Socket Cleanup
    // ========================================================================

    /**
     * Close the TCP socket and clear references.
     *
     * Safe to call multiple times (idempotent). Closing the socket also
     * unblocks any thread waiting in InputStream.read(), causing it to
     * throw IOException and exit the readLoop.
     */
    private fun closeSocket() {
        try {
            outputStream = null
            socket?.close()
            socket = null
        } catch (e: IOException) {
            Log.w(TAG, "Error closing socket: ${e.message}")
        }
    }
}
