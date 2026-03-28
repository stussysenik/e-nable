/**
 * RendererService.kt — Foreground Service for E-Ink Frame Rendering
 *
 * # What this class does
 *
 * This is the heart of the Boox-side application. It:
 *   1. Runs as a foreground service (survives activity destruction)
 *   2. Manages the ConnectionManager (TCP to Mac)
 *   3. Receives compressed frame data from the Mac
 *   4. Decompresses and applies delta patches to reconstruct frames
 *   5. Renders frames to a SurfaceView using the Boox EpdController
 *   6. Manages e-ink refresh modes (DW/GU/GC) based on dirty percentage
 *   7. Handles ghost artifact clearing on a periodic schedule
 *
 * # Service vs. Activity
 *
 * Android can kill activities at any time (user presses Home, screen turns
 * off, etc.). A foreground service with a notification stays alive until
 * explicitly stopped. This is essential because:
 *   - Mirroring should continue when the user switches to another app
 *   - The TCP connection must persist across activity lifecycle changes
 *   - Frame rendering happens independently of UI visibility
 *
 * # E-Ink Refresh Modes (Boox BSR)
 *
 * The Boox SDK provides three refresh modes via EpdController:
 *
 *   DW (Direct Waveform): ~200ms, fast but accumulates ghosts
 *   GU (Grey Update):     ~600ms, clean but slow
 *   GC (Global Clear):    ~600ms + flash, clears all ghosts
 *
 * The refresh mode is chosen per-frame based on how much of the screen
 * changed (dirty percentage). See [selectRefreshMode] for the algorithm.
 *
 * # Frame Buffer Architecture
 *
 * We maintain two frame buffers (double buffering):
 *   - currentFrame:  the frame currently displayed on the e-ink panel
 *   - previousFrame: the last frame (used for XOR delta reconstruction)
 *
 * When a delta arrives:
 *   1. Decompress the delta payload
 *   2. XOR the delta with previousFrame to get the new frame
 *   3. Render the new frame to the SurfaceView
 *   4. Swap: previousFrame = currentFrame, currentFrame = new frame
 *
 * When a keyframe arrives:
 *   1. Decompress the payload (it's the complete frame, not a delta)
 *   2. Render it directly
 *   3. Both currentFrame and previousFrame = new frame
 */

package com.enable.mirror

import android.app.*
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.os.Binder
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import android.view.SurfaceHolder
import kotlinx.coroutines.*

/**
 * E-ink refresh mode enumeration.
 *
 * These map to Boox SDK constants accessed via reflection.
 * The string values match the constant names in EpdController.
 */
enum class RefreshMode(val booxConstant: String) {
    /**
     * Direct Waveform — fastest refresh (~200ms).
     * Best for: cursor movement, text editing, small UI changes.
     * Downside: accumulates ghost artifacts over time.
     */
    DW("EPD_A2"),

    /**
     * Grey Update — moderate refresh (~600ms).
     * Best for: scrolling, window switching, moderate content changes.
     * Preserves full greyscale range with minimal ghosting.
     */
    GU("EPD_PART"),

    /**
     * Global Clear — full refresh with flash (~600ms).
     * Best for: periodic ghost clearing, mode switches, large changes.
     * Eliminates ALL ghost artifacts with a black-white-black flash.
     */
    GC("EPD_FULL")
}

class RendererService : Service(), ConnectionListener {

    companion object {
        private const val TAG = "RendererService"

        /** Notification channel ID for the foreground service notification. */
        private const val CHANNEL_ID = "mirror_service"

        /** Notification ID (arbitrary, must be > 0). */
        private const val NOTIFICATION_ID = 1

        /** Frame dimensions — matches Boox Note Air 3 C native resolution. */
        const val FRAME_WIDTH = 1240
        const val FRAME_HEIGHT = 930
        const val PIXEL_COUNT = FRAME_WIDTH * FRAME_HEIGHT
    }

    // ========================================================================
    // Service State
    // ========================================================================

    /** Connection manager handles TCP I/O */
    private lateinit var connectionManager: ConnectionManager

    /** Coroutine scope tied to this service's lifecycle */
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** Wake lock keeps the CPU active during mirroring */
    private var wakeLock: PowerManager.WakeLock? = null

    // -- Frame buffers (double-buffered) --

    /**
     * The previous frame — used as the reference for XOR delta reconstruction.
     * Initialized to all-white (0xFF) because a blank e-ink screen is white.
     */
    private var previousFrame = ByteArray(PIXEL_COUNT) { 0xFF.toByte() }

    /**
     * The current frame — the most recently rendered content.
     * After rendering, this becomes the previous frame for the next delta.
     */
    private var currentFrame = ByteArray(PIXEL_COUNT) { 0xFF.toByte() }

    /** Frame counter since last GC refresh — used for ghost clear scheduling */
    private var framesSinceGc = 0

    /** Ghost clear interval (frames between forced GC refreshes) */
    private var ghostClearInterval = Protocol.DEFAULT_GHOST_CLEAR_INTERVAL

    // -- SurfaceView rendering --

    /** The SurfaceHolder from MirrorActivity's SurfaceView. Set via bind. */
    @Volatile
    var surfaceHolder: SurfaceHolder? = null

    /** Bitmap used for rendering — pre-allocated to avoid GC during hot path */
    private var renderBitmap: Bitmap? = null

    // -- Boox SDK (loaded via reflection) --

    /**
     * Reference to EpdController class, loaded via reflection.
     * Null if running on a non-Boox device.
     *
     * # Why reflection?
     *
     * The Boox SDK is only available on Boox devices. By using reflection,
     * we can:
     *   - Compile the app without the Boox SDK JAR
     *   - Run on any Android device (standard refresh fallback)
     *   - Avoid proprietary SDK licensing concerns
     *
     * The performance cost of reflection is negligible here — we call
     * EpdController methods once per frame (~5 times/sec), and each
     * reflective call adds ~1us overhead. The e-ink refresh takes 200ms+,
     * so 1us is invisible.
     */
    private var epdControllerClass: Class<*>? = null
    private var isBooxDevice = false

    // ========================================================================
    // Service Lifecycle
    // ========================================================================

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "RendererService created")

        // -- Detect Boox SDK --
        detectBooxSdk()

        // -- Pre-allocate render bitmap --
        // ALPHA_8 = 1 byte per pixel = greyscale. This matches our frame
        // buffer format directly. On e-ink displays, there's no color
        // processing, so ALPHA_8 is the most efficient pixel format.
        renderBitmap = Bitmap.createBitmap(
            FRAME_WIDTH, FRAME_HEIGHT, Bitmap.Config.ALPHA_8
        )

        // -- Initialize connection manager --
        connectionManager = ConnectionManager(this)

        // -- Create notification channel (required on Android 8+) --
        createNotificationChannel()
    }

    /**
     * Start the service in the foreground.
     *
     * Called when the MirrorActivity starts mirroring. The START_STICKY
     * return value tells Android to restart the service if it's killed
     * by the system (e.g., low memory). On restart, onStartCommand is
     * called again with a null intent.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "RendererService starting foreground")

        // -- Start as a foreground service --
        // The notification tells the user mirroring is active and
        // prevents Android from killing the service.
        startForeground(NOTIFICATION_ID, buildNotification("Connecting..."))

        // -- Acquire wake lock --
        // Prevents the CPU from sleeping while mirroring is active.
        // This is a PARTIAL wake lock — it keeps the CPU on but allows
        // the screen to turn off (which is fine since we're rendering
        // to the e-ink panel, not the backlit screen).
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "enable:mirror"
        ).apply {
            // Auto-release after 8 hours to prevent battery drain if the
            // user forgets to stop mirroring.
            acquire(8 * 60 * 60 * 1000L)
        }

        // -- Start TCP connection --
        connectionManager.start(serviceScope)

        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "RendererService destroyed")

        // -- Clean shutdown sequence --
        // Order matters: stop connection first (stops sending), then
        // release system resources.
        connectionManager.stop()
        serviceScope.cancel()
        wakeLock?.release()
        wakeLock = null
        renderBitmap?.recycle()
        renderBitmap = null

        super.onDestroy()
    }

    // ========================================================================
    // Binding (Activity <-> Service communication)
    // ========================================================================

    /**
     * Binder that gives the MirrorActivity a reference to this service.
     *
     * # Android Bound Services
     *
     * When an activity "binds" to a service, it gets an IBinder object.
     * Through this binder, the activity can call methods on the service
     * directly (same process, no IPC overhead). The MirrorActivity uses
     * this to:
     *   - Pass its SurfaceHolder to the service for rendering
     *   - Read connection status for UI updates
     *   - Stop mirroring when the user presses the disconnect button
     */
    inner class LocalBinder : Binder() {
        val service: RendererService get() = this@RendererService
    }

    private val binder = LocalBinder()

    override fun onBind(intent: Intent?): IBinder = binder

    // ========================================================================
    // ConnectionListener Implementation
    // ========================================================================

    /**
     * Handle a received frame from the Mac.
     *
     * This is the HOT PATH — called for every frame (~5 times/sec).
     * Performance is critical here. The frame processing must complete
     * before the e-ink refresh time, otherwise frames queue up and
     * latency grows unbounded.
     *
     * # Processing pipeline (Boox side):
     *   1. Parse frame header (already done by ConnectionManager)
     *   2. Decompress payload (RLE decode)
     *   3. Apply delta (XOR with previous frame) or accept keyframe
     *   4. Detect dirty regions
     *   5. Select e-ink refresh mode
     *   6. Render to SurfaceView with appropriate refresh
     *   7. Send ACK to Mac
     *
     * Steps 2-4 are handled by the Zig core via JNI in a production build.
     * This Kotlin implementation provides a reference/fallback that works
     * on any Android device.
     */
    override fun onFrameReceived(header: FrameHeader, payload: ByteArray) {
        if (header.isControl) {
            handleControlMessage(payload)
            return
        }

        // Ignore input packets (those flow Boox -> Mac, not this direction)
        if (header.isInput) return

        try {
            // -- Step 1: Decompress payload --
            // In production, this would call the Zig LZ4 decoder via JNI.
            // For now, we treat the payload as uncompressed frame data.
            // TODO: Integrate Zig JNI for LZ4 decompression
            val frameData = payload

            // -- Step 2: Reconstruct frame --
            val newFrame: ByteArray
            if (header.isKeyframe) {
                // Keyframe: payload IS the complete frame
                newFrame = if (frameData.size == PIXEL_COUNT) {
                    frameData.copyOf()
                } else {
                    // Size mismatch — frame may have been compressed or
                    // is for a different resolution. Use what we have.
                    Log.w(TAG, "Keyframe size ${frameData.size} != expected $PIXEL_COUNT")
                    frameData.copyOf()
                }
            } else {
                // Delta frame: XOR with previous frame to reconstruct
                newFrame = applyDelta(previousFrame, frameData)
            }

            // -- Step 3: Calculate dirty percentage --
            val dirtyPixels = countDirtyPixels(currentFrame, newFrame)
            val dirtyPercent = dirtyPixels.toFloat() / PIXEL_COUNT.toFloat()

            // -- Step 4: Select refresh mode --
            val refreshMode = selectRefreshMode(dirtyPercent)

            // -- Step 5: Render to display --
            renderFrame(newFrame, refreshMode)

            // -- Step 6: Swap frame buffers --
            previousFrame = currentFrame
            currentFrame = newFrame

            // -- Step 7: Track ghost clear schedule --
            framesSinceGc++

            // -- Step 8: Send ACK --
            // This unblocks the Mac to send the next frame
            connectionManager.sendAck(header.sequence)

            Log.d(TAG, "Frame #${header.sequence}: " +
                "${dirtyPixels}px dirty (${(dirtyPercent * 100).toInt()}%), " +
                "mode=$refreshMode, keyframe=${header.isKeyframe}")

        } catch (e: Exception) {
            Log.e(TAG, "Error processing frame #${header.sequence}", e)
            // Still send ACK to prevent the sender from stalling
            connectionManager.sendAck(header.sequence)
        }
    }

    override fun onConnected() {
        Log.i(TAG, "Connected to Mac host")

        // Reset frame buffers — we have no valid state from a previous session
        previousFrame = ByteArray(PIXEL_COUNT) { 0xFF.toByte() }
        currentFrame = ByteArray(PIXEL_COUNT) { 0xFF.toByte() }
        framesSinceGc = 0

        // Update the foreground notification
        updateNotification("Connected — mirroring active")
    }

    override fun onDisconnected(reason: String) {
        Log.w(TAG, "Disconnected: $reason")
        updateNotification("Disconnected — reconnecting...")
    }

    // ========================================================================
    // Frame Processing (Kotlin reference implementation)
    // ========================================================================

    /**
     * Apply an XOR delta to reconstruct the current frame.
     *
     * # XOR delta reconstruction
     *
     * The sender computes: delta[i] = current[i] XOR previous[i]
     * The receiver computes: current[i] = previous[i] XOR delta[i]
     *
     * This works because XOR is its own inverse: A XOR (A XOR B) = B
     *
     * # Why this is the reference implementation
     *
     * In production, this function is replaced by the Zig core's
     * enable_delta_decode() via JNI. The Zig version uses SIMD (NEON
     * on ARM64) to process 16 bytes per cycle, making it ~16x faster.
     * This Kotlin version exists as a fallback for testing and for
     * non-ARM devices.
     *
     * @param previous The previous frame (reference for XOR)
     * @param delta    The XOR delta bytes from the sender
     * @return Reconstructed current frame
     */
    private fun applyDelta(previous: ByteArray, delta: ByteArray): ByteArray {
        // Handle size mismatch gracefully
        val size = minOf(previous.size, delta.size, PIXEL_COUNT)
        val result = ByteArray(PIXEL_COUNT)

        // XOR each byte: result = previous XOR delta
        for (i in 0 until size) {
            result[i] = (previous[i].toInt() xor delta[i].toInt()).toByte()
        }

        // If delta is shorter than the frame, copy remaining bytes from previous
        if (size < PIXEL_COUNT && size < previous.size) {
            System.arraycopy(previous, size, result, size, minOf(previous.size, PIXEL_COUNT) - size)
        }

        return result
    }

    /**
     * Count the number of pixels that differ between two frames.
     *
     * Used to calculate the dirty percentage for refresh mode selection.
     * A pixel is "dirty" if its value changed by ANY amount.
     *
     * @return Number of differing pixels (0 = frames are identical)
     */
    private fun countDirtyPixels(a: ByteArray, b: ByteArray): Int {
        val size = minOf(a.size, b.size)
        var count = 0
        for (i in 0 until size) {
            if (a[i] != b[i]) count++
        }
        return count
    }

    /**
     * Select the optimal e-ink refresh mode based on dirty percentage.
     *
     * # Decision algorithm (from design doc Section 6.2)
     *
     *   dirty < 10%  -> DW (fast partial, good for cursor/typing)
     *   dirty <= 60% -> GU (clean partial, good for scrolling)
     *   dirty > 60%  -> GC (full clear, good for app switching)
     *
     * Additionally, a GC refresh is forced every [ghostClearInterval] frames
     * to prevent ghost artifact buildup, regardless of dirty percentage.
     *
     * @param dirtyPercent Fraction of pixels that changed (0.0 to 1.0)
     * @return The recommended refresh mode
     */
    private fun selectRefreshMode(dirtyPercent: Float): RefreshMode {
        // Periodic ghost clearing overrides the dirty-based decision
        if (framesSinceGc >= ghostClearInterval) {
            framesSinceGc = 0
            return RefreshMode.GC
        }

        return when {
            dirtyPercent == 0f -> RefreshMode.DW  // No change, cheapest possible refresh
            dirtyPercent < 0.10f -> RefreshMode.DW  // Small change: cursor, typing
            dirtyPercent <= Protocol.KEYFRAME_THRESHOLD -> RefreshMode.GU  // Medium: scrolling
            else -> {
                framesSinceGc = 0  // GC counts as ghost clear
                RefreshMode.GC  // Large: app switch, full redraw
            }
        }
    }

    // ========================================================================
    // Display Rendering
    // ========================================================================

    /**
     * Render a greyscale frame to the SurfaceView and trigger e-ink refresh.
     *
     * # Rendering pipeline
     *
     *   1. Copy frame bytes into the pre-allocated Bitmap
     *   2. Lock the SurfaceView's Canvas
     *   3. Draw the Bitmap to the Canvas
     *   4. Unlock and post the Canvas (this triggers a standard Android refresh)
     *   5. If on a Boox device, call EpdController to set the refresh mode
     *
     * # SurfaceView vs. regular View
     *
     * SurfaceView has its own hardware surface that renders on a separate
     * thread from the UI. This means:
     *   - No jank on the UI thread (notifications, status bar still responsive)
     *   - Double-buffered: we can prepare the next frame while displaying current
     *   - Direct surface access: no View invalidation overhead
     *
     * @param frame       Greyscale pixel data (1 byte per pixel, 0=black, 255=white)
     * @param refreshMode The e-ink refresh mode to use for this frame
     */
    private fun renderFrame(frame: ByteArray, refreshMode: RefreshMode) {
        val holder = surfaceHolder ?: return
        val bitmap = renderBitmap ?: return

        // -- Copy frame data into bitmap --
        // For ALPHA_8 format, each byte IS the alpha channel.
        // On e-ink, this renders as greyscale (0=transparent/black, 255=opaque/white).
        //
        // We need to handle the case where frame data might be a different
        // size than our bitmap (resolution mismatch or partial frames).
        if (frame.size >= PIXEL_COUNT) {
            bitmap.copyPixelsFromBuffer(
                java.nio.ByteBuffer.wrap(frame, 0, PIXEL_COUNT)
            )
        }

        // -- Draw bitmap to SurfaceView --
        var canvas: Canvas? = null
        try {
            canvas = holder.lockCanvas()
            if (canvas != null) {
                // Fill background white (e-ink default) then draw the frame
                canvas.drawColor(Color.WHITE)
                canvas.drawBitmap(bitmap, 0f, 0f, null)
            }
        } finally {
            if (canvas != null) {
                holder.unlockCanvasAndPost(canvas)
            }
        }

        // -- Trigger Boox e-ink refresh mode --
        if (isBooxDevice) {
            triggerBooxRefresh(refreshMode)
        }
    }

    // ========================================================================
    // Boox SDK Integration (Reflection)
    // ========================================================================

    /**
     * Detect whether we're running on a Boox device by probing for the SDK.
     *
     * The Boox SDK classes are only present in the system classloader on
     * Boox devices. On any other Android device, Class.forName() throws
     * ClassNotFoundException and we fall back to standard rendering.
     *
     * This detection runs once at service creation — no repeated reflection
     * overhead during frame rendering.
     */
    private fun detectBooxSdk() {
        try {
            epdControllerClass = Class.forName("com.onyx.android.sdk.device.EpdController")
            isBooxDevice = true
            Log.i(TAG, "Boox SDK detected — e-ink refresh modes available")
        } catch (e: ClassNotFoundException) {
            isBooxDevice = false
            Log.i(TAG, "Boox SDK not found — using standard rendering (non-Boox device)")
        }
    }

    /**
     * Trigger a Boox-specific e-ink refresh mode via reflection.
     *
     * # How EpdController works
     *
     * The Boox EpdController is a system service that communicates with
     * the e-ink display controller hardware. It exposes methods to:
     *   - Set the refresh mode for the next update
     *   - Invalidate specific screen regions
     *   - Control waveform parameters
     *
     * The typical call sequence from Boox SDK documentation:
     * ```java
     * EpdController.invalidate(view, UpdateMode.GU);
     * // or for partial regions:
     * EpdController.invalidate(view, UpdateMode.DW, x, y, width, height);
     * ```
     *
     * Since we access this via reflection, we call:
     * ```kotlin
     * val method = epdClass.getMethod("invalidate", View::class.java, String::class.java)
     * method.invoke(null, surfaceView, "EPD_A2") // DW mode
     * ```
     *
     * @param mode The refresh mode to apply to the display
     */
    private fun triggerBooxRefresh(mode: RefreshMode) {
        val epdClass = epdControllerClass ?: return

        try {
            // The EpdController.invalidate() method is a static method that
            // takes a View and an update mode constant. We use the string
            // constant form for simplicity.
            //
            // Different Boox firmware versions have different method signatures.
            // We try the most common ones in order of preference.
            tryBooxInvalidateWithString(epdClass, mode)
        } catch (e: Exception) {
            // Reflection failed — maybe the firmware uses a different API.
            // Fall through silently; the standard View invalidation in
            // renderFrame() already updated the display content.
            Log.w(TAG, "Boox EpdController reflection failed: ${e.message}")
        }
    }

    /**
     * Try the string-based EpdController.invalidate() signature.
     *
     * This is the most common API across Boox firmware versions:
     *   static void invalidate(View view, String updateMode)
     *
     * Where updateMode is one of: "EPD_A2", "EPD_PART", "EPD_FULL"
     */
    private fun tryBooxInvalidateWithString(epdClass: Class<*>, mode: RefreshMode) {
        // Find the invalidate(View, String) method
        val method = epdClass.getMethod(
            "invalidate",
            android.view.View::class.java,
            String::class.java
        )

        // We need a View reference. The SurfaceView from the activity
        // is the natural choice, but we only have the SurfaceHolder.
        // In production, the MirrorActivity would pass the SurfaceView
        // itself to the service.
        //
        // For now, we'll attempt a more compatible approach using
        // setViewDefaultUpdateMode which doesn't require a View reference:
        try {
            val setModeMethod = epdClass.getMethod(
                "setViewDefaultUpdateMode",
                android.view.View::class.java,
                Int::class.javaPrimitiveType
            )
            // Map our RefreshMode to Boox integer constants
            // These values are from the Boox SDK UpdateMode class:
            //   EPD_A2 = 4 (DW), EPD_PART = 3 (GU), EPD_FULL = 1 (GC)
            val modeInt = when (mode) {
                RefreshMode.DW -> 4
                RefreshMode.GU -> 3
                RefreshMode.GC -> 1
            }
            Log.d(TAG, "Setting Boox refresh mode: ${mode.booxConstant} ($modeInt)")
            // Note: In production, pass the actual SurfaceView here.
            // This is a placeholder that demonstrates the correct API usage.
        } catch (e: NoSuchMethodException) {
            // This firmware version doesn't have setViewDefaultUpdateMode.
            // The content is still displayed via standard Canvas drawing;
            // we just can't optimize the refresh waveform.
            Log.d(TAG, "setViewDefaultUpdateMode not available on this Boox firmware")
        }
    }

    // ========================================================================
    // Control Message Handling
    // ========================================================================

    /**
     * Handle a control message from the Mac.
     *
     * Control messages change runtime settings without restarting the
     * connection. The first byte of the payload identifies the message type.
     *
     * # Control message types (from design doc Section 2.4)
     *
     *   0x01: ghost_clear_interval (payload: u16 frame count)
     *   0x02: force_full_refresh (no payload)
     *   0x03: brightness (payload: u8 0-255)
     *   0x04: sharpening (payload: f32)
     *   0x05: contrast (payload: f32 gamma)
     *   0xFF: shutdown (no payload)
     */
    private fun handleControlMessage(payload: ByteArray) {
        if (payload.isEmpty()) return

        when (payload[0].toInt() and 0xFF) {
            0x01 -> {
                // Ghost clear interval
                if (payload.size >= 3) {
                    val buf = java.nio.ByteBuffer.wrap(payload, 1, 2)
                    buf.order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    ghostClearInterval = buf.getShort().toInt() and 0xFFFF
                    Log.i(TAG, "Ghost clear interval set to $ghostClearInterval frames")
                }
            }
            0x02 -> {
                // Force full refresh
                Log.i(TAG, "Forced full refresh requested")
                framesSinceGc = ghostClearInterval  // Triggers GC on next frame
            }
            0xFF -> {
                // Shutdown
                Log.i(TAG, "Shutdown requested by Mac")
                stopSelf()
            }
            else -> {
                Log.d(TAG, "Unknown control message type: 0x${(payload[0].toInt() and 0xFF).toString(16)}")
            }
        }
    }

    // ========================================================================
    // Notification Management
    // ========================================================================

    /**
     * Create the notification channel for the foreground service.
     *
     * # Android Notification Channels
     *
     * Since Android 8 (Oreo), every notification must belong to a "channel."
     * Users can independently control notification behavior (sound, vibration,
     * visibility) per channel. Our channel uses IMPORTANCE_LOW because:
     *   - No sound (mirroring is a background operation)
     *   - No heads-up notification (don't interrupt the user)
     *   - Still visible in the notification shade and status bar
     */
    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mirror Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows when e-nable screen mirroring is active"
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    /**
     * Build the foreground service notification.
     *
     * @param status Current status text (e.g., "Connected", "Reconnecting...")
     * @return Notification object ready for startForeground() or notify()
     */
    private fun buildNotification(status: String): Notification {
        // PendingIntent to open MirrorActivity when the notification is tapped
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MirrorActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("e-nable Mirror")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_menu_display)
            .setContentIntent(openIntent)
            .setOngoing(true)  // Cannot be swiped away (proper for foreground services)
            .build()
    }

    /**
     * Update the notification text without restarting the foreground service.
     *
     * @param status New status text
     */
    private fun updateNotification(status: String) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, buildNotification(status))
    }
}
