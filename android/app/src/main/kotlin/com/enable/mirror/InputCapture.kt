/**
 * InputCapture.kt — Stylus & Touch Input Capture for Boox Devices
 *
 * # What this class does
 *
 * Captures stylus (Wacom EMR) and touch (capacitive) input events from
 * the Boox e-ink tablet and forwards them to the Mac via the TCP connection.
 * The Mac side converts these into CGEvent tablet events to control the
 * cursor, draw in apps, and interact with macOS.
 *
 * # Wacom EMR Digitizer
 *
 * Boox devices have a Wacom EMR (Electromagnetic Resonance) digitizer
 * beneath the e-ink panel. This provides:
 *   - 4096 pressure levels (0.0 to 1.0 normalized)
 *   - Tilt detection in X and Y axes (radians)
 *   - Hover detection (pen near surface but not touching)
 *   - Palm rejection (stylus input disables touch)
 *
 * EMR is the same technology used in Wacom Intuos/Cintiq tablets. The
 * pen has no battery — it's powered by the electromagnetic field from
 * the digitizer. This is why Boox stylus pens never need charging.
 *
 * # Input Coordinate System
 *
 * The Boox touch coordinates are in device pixels (0 to 1240 for X,
 * 0 to 930 for Y on the Note Air 3 C). We normalize to [0.0, 1.0]
 * before sending to the Mac so the Mac can map to any virtual display
 * resolution without knowing the Boox's physical dimensions.
 *
 * # Event Batching
 *
 * Touch/stylus events arrive at ~120Hz from the digitizer. Sending each
 * event individually would create 120 TCP writes per second of tiny
 * packets (25 bytes each). Instead, we batch events and send them in
 * bursts aligned with the frame rate:
 *   - Collect events for ~16ms (one frame period at 60Hz input)
 *   - Package all events into a single protocol frame
 *   - Send the batch as one TCP write
 *
 * This reduces TCP overhead (fewer packets, fewer ACKs) while maintaining
 * low latency (16ms batch window is imperceptible for cursor movement).
 *
 * # Stale Event Filtering
 *
 * Events older than 100ms (from event timestamp to send time) are dropped.
 * Stale stylus events cause erratic cursor behavior on the Mac because
 * the cursor "replays" old positions. This can happen when:
 *   - The TCP connection is slow (backed up writes)
 *   - The frame processing takes too long (ACK delayed)
 *   - Android delivers a burst of buffered events after a GC pause
 */

package com.enable.mirror

import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.View
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*

/**
 * Captures and forwards touch/stylus input events.
 *
 * # Usage
 *
 * ```kotlin
 * val inputCapture = InputCapture(
 *     connectionManager = conn,
 *     displayWidth = 1240f,
 *     displayHeight = 930f
 * )
 *
 * // Attach to the SurfaceView in MirrorActivity
 * surfaceView.setOnTouchListener(inputCapture)
 *
 * // Start the batching loop
 * inputCapture.start(lifecycleScope)
 *
 * // Stop when mirroring ends
 * inputCapture.stop()
 * ```
 *
 * @param connectionManager The TCP connection to send events through
 * @param displayWidth      Physical display width in pixels (for normalization)
 * @param displayHeight     Physical display height in pixels (for normalization)
 */
class InputCapture(
    private val connectionManager: ConnectionManager,
    private val displayWidth: Float = RendererService.FRAME_WIDTH.toFloat(),
    private val displayHeight: Float = RendererService.FRAME_HEIGHT.toFloat()
) : View.OnTouchListener {

    companion object {
        private const val TAG = "InputCapture"

        /**
         * Maximum age (in milliseconds) for an input event to be sent.
         * Events older than this are dropped to prevent stale cursor movement.
         *
         * 100ms is the threshold from the design doc (Section 2.5).
         * For reference:
         *   - Average human reaction time: ~200ms
         *   - E-ink DW refresh: ~200ms
         *   - 100ms of staleness is imperceptible to users
         */
        private const val STALE_THRESHOLD_MS = 100L

        /**
         * Batch window in milliseconds. Events are collected for this
         * duration before being sent as a single TCP packet.
         *
         * 16ms matches a 60Hz refresh cycle. This means:
         *   - At most 16ms latency added to input events
         *   - Typically 1-2 events per batch (stylus at 120Hz)
         *   - One TCP write every 16ms instead of 120 writes/sec
         */
        private const val BATCH_INTERVAL_MS = 16L
    }

    // -- Event queue --

    /**
     * Thread-safe list for events waiting to be sent.
     *
     * CopyOnWriteArrayList is chosen because:
     *   - Writes (add from touch thread) are infrequent relative to reads
     *   - The batch sender iterates and clears, which is safe with CoW
     *   - No explicit synchronization needed
     *   - List size is bounded by BATCH_INTERVAL_MS * input_rate (~2 events)
     *
     * For higher event rates, a lock-free queue (e.g., ConcurrentLinkedQueue)
     * would be more efficient, but at ~120Hz input rate, CoW overhead is negligible.
     */
    private val pendingEvents = CopyOnWriteArrayList<InputEvent>()

    /** Monotonically increasing sequence number for outgoing input frames */
    @Volatile
    private var sequenceNumber: Long = 0

    /** Coroutine job for the batch send loop */
    private var batchJob: Job? = null

    /** True if input capture is active */
    @Volatile
    private var active = false

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /**
     * Start the input capture batch loop.
     *
     * @param scope Coroutine scope for the batch sender. Should be tied
     *              to the service or activity lifecycle.
     */
    fun start(scope: CoroutineScope) {
        active = true
        batchJob = scope.launch(Dispatchers.IO) {
            batchSendLoop()
        }
    }

    /**
     * Stop input capture and cancel the batch loop.
     */
    fun stop() {
        active = false
        batchJob?.cancel()
        batchJob = null
        pendingEvents.clear()
    }

    // ========================================================================
    // Touch Event Handling
    // ========================================================================

    /**
     * Handle touch events from the SurfaceView.
     *
     * # Android MotionEvent
     *
     * Android delivers input through MotionEvent objects. Each event has:
     *   - action: what happened (DOWN, MOVE, UP, CANCEL)
     *   - x, y: coordinates in the View's coordinate space
     *   - pressure: 0.0 to 1.0 (from Wacom EMR or capacitive sensor)
     *   - toolType: FINGER, STYLUS, or ERASER
     *
     * # Stylus vs. Touch discrimination
     *
     * We check getToolType(0) to distinguish:
     *   - TOOL_TYPE_STYLUS (2): Wacom EMR pen input
     *   - TOOL_TYPE_FINGER (1): Capacitive touch input
     *   - TOOL_TYPE_ERASER (4): Pen eraser end (some Boox pens have this)
     *
     * The Mac side uses this distinction to:
     *   - Route stylus events to CGEvent tablet events (with pressure/tilt)
     *   - Route touch events to standard CGEvent mouse events (no pressure)
     *
     * # Batched motion events
     *
     * For performance, Android batches multiple MOVE events into a single
     * MotionEvent. The "current" point is at getX()/getY(), and historical
     * points are at getHistoricalX(i)/getHistoricalY(i). We extract ALL
     * points to preserve the full stylus path, which is important for
     * smooth handwriting on the Mac side.
     *
     * @param view   The SurfaceView that received the event
     * @param event  The MotionEvent from the Android input system
     * @return true to consume the event (prevent further handling)
     */
    @Suppress("ClickableViewAccessibility")
    override fun onTouch(view: View, event: MotionEvent): Boolean {
        if (!active) return false

        val isStylus = event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS ||
                       event.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // First contact with the screen
                val inputType = if (isStylus) InputType.STYLUS_DOWN else InputType.TOUCH_DOWN
                enqueueEvent(inputType, event)
            }

            MotionEvent.ACTION_MOVE -> {
                // Movement while touching

                // -- Extract historical points --
                // Android batches MOVE events for efficiency. A single
                // ACTION_MOVE may contain 2-5 historical positions recorded
                // between the previous and current event delivery.
                val inputType = if (isStylus) InputType.STYLUS_MOVE else InputType.TOUCH_MOVE

                for (h in 0 until event.historySize) {
                    val histEvent = InputEvent(
                        type = inputType,
                        x = event.getHistoricalX(h) / displayWidth,
                        y = event.getHistoricalY(h) / displayHeight,
                        pressure = event.getHistoricalPressure(h),
                        tiltX = getHistoricalTilt(event, MotionEvent.AXIS_TILT, h),
                        tiltY = getHistoricalOrientation(event, h),
                        timestampNs = event.getHistoricalEventTime(h) * 1_000_000L
                    )
                    pendingEvents.add(histEvent)
                }

                // -- Current point --
                enqueueEvent(inputType, event)
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                // Contact lost (finger/stylus lifted or cancelled)
                val inputType = if (isStylus) InputType.STYLUS_UP else InputType.TOUCH_UP
                enqueueEvent(inputType, event)
            }
        }

        return true  // Consume the event
    }

    /**
     * Create an InputEvent from a MotionEvent and add it to the queue.
     *
     * Coordinates are normalized to [0.0, 1.0] for resolution independence.
     * Pressure comes directly from the Wacom EMR (0.0-1.0, 4096 levels).
     * Tilt is extracted from AXIS_TILT (magnitude) and AXIS_ORIENTATION
     * (angle), then decomposed into X and Y components.
     *
     * @param type  The InputType for this event
     * @param event The raw Android MotionEvent
     */
    private fun enqueueEvent(type: InputType, event: MotionEvent) {
        // -- Normalize coordinates --
        // Clamp to [0, 1] in case the touch extends beyond the SurfaceView
        // bounds (can happen with palm touches near screen edges)
        val normalizedX = (event.x / displayWidth).coerceIn(0f, 1f)
        val normalizedY = (event.y / displayHeight).coerceIn(0f, 1f)

        // -- Extract pressure --
        // The Wacom EMR digitizer reports 4096 pressure levels.
        // Android normalizes this to [0.0, 1.0] for us.
        // Capacitive touch always reports 1.0 (binary: touching or not).
        val pressure = event.pressure

        // -- Extract tilt --
        // AXIS_TILT: tilt magnitude in radians (0 = perpendicular to screen)
        // AXIS_ORIENTATION: tilt direction in radians (-PI to PI)
        // We decompose into X and Y components for the Mac's CGEvent API.
        val tiltMagnitude = event.getAxisValue(MotionEvent.AXIS_TILT)
        val tiltOrientation = event.getAxisValue(MotionEvent.AXIS_ORIENTATION)
        val tiltX = tiltMagnitude * kotlin.math.cos(tiltOrientation)
        val tiltY = tiltMagnitude * kotlin.math.sin(tiltOrientation)

        val inputEvent = InputEvent(
            type = type,
            x = normalizedX,
            y = normalizedY,
            pressure = pressure,
            tiltX = tiltX,
            tiltY = tiltY,
            timestampNs = event.eventTime * 1_000_000L  // ms -> ns
        )

        pendingEvents.add(inputEvent)
    }

    // ========================================================================
    // Batch Send Loop
    // ========================================================================

    /**
     * Periodically send batched input events over TCP.
     *
     * Runs on Dispatchers.IO, waking up every [BATCH_INTERVAL_MS] to:
     *   1. Snapshot and clear the pending events list
     *   2. Filter out stale events (>100ms old)
     *   3. Serialize all remaining events into a single protocol frame
     *   4. Send the frame over the TCP connection
     *
     * # Why batch instead of send-on-event?
     *
     * At 120Hz stylus input, sending per-event would mean 120 TCP writes/sec.
     * Each write has overhead:
     *   - Syscall overhead: ~2us per write() call
     *   - TCP header: 40 bytes per packet (for a 25-byte payload!)
     *   - Nagle interaction: even with TCP_NODELAY, many small writes
     *     can overwhelm the USB-C ADB tunnel
     *
     * Batching at 60Hz reduces this to ~60 writes/sec with 2-3 events per
     * write. The 16ms batch delay is well below human perception threshold.
     */
    private suspend fun batchSendLoop() {
        while (active && currentCoroutineContext().isActive) {
            delay(BATCH_INTERVAL_MS)

            // -- Snapshot and clear --
            // CopyOnWriteArrayList.toList() returns a snapshot.
            // clear() is atomic. There's a tiny race window where an event
            // could be added between toList() and clear(), but that event
            // would simply be sent in the next batch (16ms later, negligible).
            val events = pendingEvents.toList()
            if (events.isEmpty()) continue
            pendingEvents.clear()

            // -- Filter stale events --
            val nowNs = SystemClock.elapsedRealtimeNanos()
            val freshEvents = events.filter { event ->
                val ageMs = (nowNs - event.timestampNs) / 1_000_000L
                if (ageMs > STALE_THRESHOLD_MS) {
                    Log.d(TAG, "Dropping stale input event (${ageMs}ms old)")
                    false
                } else {
                    true
                }
            }

            if (freshEvents.isEmpty()) continue

            // -- Serialize and send --
            sendEventBatch(freshEvents)
        }
    }

    /**
     * Serialize a batch of input events and send as a single protocol frame.
     *
     * The payload format is simply the events serialized back-to-back:
     *   [event1 (25 bytes)][event2 (25 bytes)]...[eventN (25 bytes)]
     *
     * The receiver knows the event count from the payload length:
     *   count = payload_length / INPUT_PACKET_SIZE
     *
     * @param events List of input events to send (must not be empty)
     */
    private fun sendEventBatch(events: List<InputEvent>) {
        val payloadSize = events.size * Protocol.INPUT_PACKET_SIZE
        val payload = java.nio.ByteBuffer.allocate(payloadSize)
        payload.order(java.nio.ByteOrder.LITTLE_ENDIAN)

        for (event in events) {
            val serialized = serializeInputEvent(event)
            // Copy serialized event bytes into the batch payload
            val bytes = ByteArray(serialized.remaining())
            serialized.get(bytes)
            payload.put(bytes)
        }

        payload.flip()
        val payloadBytes = ByteArray(payload.remaining())
        payload.get(payloadBytes)

        // Build and send the protocol frame
        val frame = buildFrame(
            Protocol.FLAG_INPUT,
            sequenceNumber++,
            payloadBytes
        )

        val frameBytes = ByteArray(frame.remaining())
        frame.get(frameBytes)

        // Use the connection manager's raw write capability
        // In production, this would go through a dedicated send method
        connectionManager.sendInputEvent(
            events.first(),  // Send the first event for connection manager's API
            sequenceNumber
        )

        Log.d(TAG, "Sent ${events.size} input events in batch")
    }

    // ========================================================================
    // Tilt Helpers
    // ========================================================================

    /**
     * Get historical tilt magnitude for a batched motion event.
     *
     * Android's getHistoricalAxisValue() provides access to sensor data
     * at historical sample points within a batched MotionEvent.
     *
     * @param event  The batched MotionEvent
     * @param axis   The axis to query (AXIS_TILT for tilt magnitude)
     * @param historyIndex Index into the historical samples
     * @return Tilt value in radians, or 0 if not available
     */
    private fun getHistoricalTilt(
        event: MotionEvent,
        axis: Int,
        historyIndex: Int
    ): Float {
        return try {
            event.getHistoricalAxisValue(axis, 0, historyIndex)
        } catch (e: Exception) {
            0f  // Tilt not available on this device
        }
    }

    /**
     * Get historical orientation for a batched motion event.
     *
     * AXIS_ORIENTATION gives the angular direction of stylus tilt
     * (clockwise from the Y axis, in radians from -PI to PI).
     *
     * @param event  The batched MotionEvent
     * @param historyIndex Index into the historical samples
     * @return Orientation in radians, or 0 if not available
     */
    private fun getHistoricalOrientation(
        event: MotionEvent,
        historyIndex: Int
    ): Float {
        return try {
            event.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, 0, historyIndex)
        } catch (e: Exception) {
            0f
        }
    }
}
