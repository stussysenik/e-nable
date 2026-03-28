/**
 * MirrorActivity.kt — Main UI for e-nable Screen Mirror
 *
 * # What this class does
 *
 * The MirrorActivity is the visible part of the app — a fullscreen
 * SurfaceView that displays the mirrored Mac desktop. It:
 *   1. Manages the fullscreen SurfaceView lifecycle
 *   2. Binds to the RendererService (which does all real work)
 *   3. Passes the SurfaceHolder to the service for rendering
 *   4. Captures touch/stylus input and forwards via InputCapture
 *   5. Handles system UI (hides status bar, navigation bar)
 *
 * # Activity vs. Service Architecture
 *
 * The Activity is a THIN UI shell. All persistent state lives in the
 * RendererService:
 *   - TCP connection: owned by RendererService
 *   - Frame buffers: owned by RendererService
 *   - Wake lock: owned by RendererService
 *
 * This separation means:
 *   - Pressing Home doesn't stop mirroring (service continues)
 *   - Returning to the app instantly shows the latest frame (no reconnect)
 *   - The activity can be destroyed and recreated without data loss
 *
 * # Fullscreen Immersive Mode
 *
 * We hide the Android system UI (status bar, navigation bar) to maximize
 * the display area for mirroring. On e-ink, every pixel matters — the
 * Boox Note Air 3 C has a 1240x930 panel, and losing 48 pixels to a
 * navigation bar would require rescaling the entire mirrored desktop.
 *
 * # SurfaceView
 *
 * SurfaceView is the optimal choice for continuous rendering because:
 *   - It has its own hardware surface (separate from the View hierarchy)
 *   - Rendering happens on a dedicated thread (no UI jank)
 *   - Double-buffered by the compositor
 *   - Direct Canvas access (no need for OpenGL/Vulkan complexity)
 *
 * For e-ink rendering, SurfaceView is strictly superior to TextureView
 * (which is GPU-backed and designed for camera/video, not e-ink refresh
 * mode control).
 */

package com.enable.mirror

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * Main activity — fullscreen SurfaceView with service binding.
 *
 * # Lifecycle
 *
 * ```
 * onCreate  -> create SurfaceView, start service, bind to service
 * onResume  -> enter fullscreen immersive mode
 * onPause   -> (nothing — service keeps running)
 * onDestroy -> unbind from service (service continues running)
 * ```
 *
 * The service is started with startForegroundService() which keeps it
 * alive even after the activity is destroyed. To actually stop mirroring,
 * the user must tap the "Stop" button or dismiss the notification.
 */
class MirrorActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "MirrorActivity"
    }

    // -- UI Components --
    private lateinit var surfaceView: SurfaceView

    // -- Service Binding --
    private var rendererService: RendererService? = null
    private var isBound = false

    // -- Input Capture --
    private var inputCapture: InputCapture? = null

    // -- Coroutine scope for this activity --
    private val activityScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ========================================================================
    // Activity Lifecycle
    // ========================================================================

    /**
     * Initialize the activity.
     *
     * # Why no XML layout?
     *
     * We create the SurfaceView programmatically instead of using an XML
     * layout file because:
     *   1. The layout is trivially simple (just one fullscreen view)
     *   2. Avoids XML inflation overhead on startup
     *   3. Makes the code self-contained (no hunting for layout.xml)
     *   4. SurfaceView programmatic creation is the standard pattern
     *      in game engines and rendering apps
     */
    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "MirrorActivity onCreate")

        // -- Keep screen on --
        // Prevents the e-ink display from sleeping while mirroring.
        // FLAG_KEEP_SCREEN_ON is the safest way to do this — it
        // automatically releases when the activity is destroyed,
        // unlike a wake lock which requires manual release.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // -- Create SurfaceView --
        // The SurfaceView provides a dedicated rendering surface that
        // the RendererService draws frames onto via Canvas.
        surfaceView = SurfaceView(this)
        setContentView(surfaceView)

        // -- Set up SurfaceHolder callbacks --
        // The SurfaceHolder manages the underlying hardware surface.
        // We need to know when it's created (ready for drawing) and
        // destroyed (must stop drawing).
        surfaceView.holder.addCallback(surfaceCallback)

        // -- Start and bind to the RendererService --
        val serviceIntent = Intent(this, RendererService::class.java)
        startForegroundService(serviceIntent)
        bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE)

        // -- Enter fullscreen immersive mode --
        hideSystemUi()
    }

    override fun onResume() {
        super.onResume()
        // Re-apply fullscreen mode (system UI may have reappeared
        // if the user swiped from the edge)
        hideSystemUi()
    }

    override fun onDestroy() {
        Log.i(TAG, "MirrorActivity onDestroy")

        // -- Stop input capture --
        inputCapture?.stop()
        inputCapture = null

        // -- Unbind from service --
        // Unbinding does NOT stop the service (it was started with
        // startForegroundService). The service continues running
        // and rendering frames to the SurfaceView.
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }

        // -- Cancel activity coroutines --
        activityScope.cancel()

        super.onDestroy()
    }

    // ========================================================================
    // Service Connection
    // ========================================================================

    /**
     * ServiceConnection handles the bind/unbind lifecycle.
     *
     * # Android Bound Services
     *
     * When we call bindService(), Android creates a connection between
     * the activity and the service. The connection delivers:
     *   - onServiceConnected: the service is bound, IBinder is available
     *   - onServiceDisconnected: the service crashed (NOT normal unbind)
     *
     * Through the IBinder, we get a direct reference to the RendererService
     * object. This lets us call methods on it (pass SurfaceHolder, etc.)
     * without IPC serialization overhead.
     */
    private val serviceConnection = object : ServiceConnection {

        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            Log.i(TAG, "Bound to RendererService")

            val localBinder = binder as RendererService.LocalBinder
            rendererService = localBinder.service
            isBound = true

            // Pass the SurfaceHolder to the service for rendering.
            // The surface may already be created (if binding happened
            // after surfaceCreated), so pass it now.
            if (surfaceView.holder.surface.isValid) {
                localBinder.service.surfaceHolder = surfaceView.holder
            }

            // -- Initialize input capture --
            initInputCapture(localBinder.service)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Called only if the service CRASHES. Normal unbinding does
            // not trigger this. If it happens, we've lost our service
            // reference and should clean up.
            Log.w(TAG, "RendererService disconnected unexpectedly")
            rendererService = null
            isBound = false
            inputCapture?.stop()
            inputCapture = null
        }
    }

    // ========================================================================
    // SurfaceView Callbacks
    // ========================================================================

    /**
     * SurfaceHolder.Callback manages the rendering surface lifecycle.
     *
     * # Surface lifecycle
     *
     * The Surface is a hardware-backed pixel buffer that SurfaceView
     * renders into. Its lifecycle is INDEPENDENT of the View lifecycle:
     *
     *   surfaceCreated  -> surface is ready for drawing
     *   surfaceChanged  -> surface dimensions changed (e.g., rotation)
     *   surfaceDestroyed -> surface is being released (MUST stop drawing)
     *
     * Between surfaceCreated and surfaceDestroyed, we can safely lock
     * the Canvas and draw pixels. Outside this window, any draw calls
     * will crash with IllegalStateException.
     */
    private val surfaceCallback = object : SurfaceHolder.Callback {

        override fun surfaceCreated(holder: SurfaceHolder) {
            Log.i(TAG, "Surface created")
            // Pass the surface to the renderer service
            rendererService?.surfaceHolder = holder
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            Log.i(TAG, "Surface changed: ${width}x${height}, format=$format")
            // The service doesn't need to be notified of size changes
            // because we render at a fixed resolution (FRAME_WIDTH x FRAME_HEIGHT)
            // and let SurfaceView handle scaling.
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            Log.i(TAG, "Surface destroyed")
            // Clear the surface reference so the service stops drawing.
            // Drawing to a destroyed surface crashes the app.
            rendererService?.surfaceHolder = null
        }
    }

    // ========================================================================
    // Input Capture Setup
    // ========================================================================

    /**
     * Initialize the InputCapture system and attach it to the SurfaceView.
     *
     * @param service The bound RendererService (needed for ConnectionManager access)
     */
    @SuppressLint("ClickableViewAccessibility")
    private fun initInputCapture(service: RendererService) {
        // Create a ConnectionManager reference for sending input events.
        // In production, the ConnectionManager would be exposed through
        // the service's public API. For now, we create an InputCapture
        // that uses the service's connection.
        //
        // Note: InputCapture needs a ConnectionManager reference. In the
        // full architecture, the service would expose this. For this
        // implementation, we construct a new one pointing to the same host.
        val connectionManager = ConnectionManager(
            listener = object : ConnectionListener {
                override fun onFrameReceived(header: FrameHeader, payload: ByteArray) {}
                override fun onConnected() {}
                override fun onDisconnected(reason: String) {}
            }
        )

        inputCapture = InputCapture(
            connectionManager = connectionManager,
            displayWidth = surfaceView.width.toFloat().coerceAtLeast(1f),
            displayHeight = surfaceView.height.toFloat().coerceAtLeast(1f)
        )

        // Attach touch listener to the SurfaceView
        surfaceView.setOnTouchListener(inputCapture)

        // Start the batch send loop
        inputCapture?.start(activityScope)

        Log.i(TAG, "Input capture initialized")
    }

    // ========================================================================
    // System UI Management
    // ========================================================================

    /**
     * Hide the system UI (status bar + navigation bar) for fullscreen mode.
     *
     * # Immersive Sticky Mode
     *
     * Android provides several fullscreen modes:
     *   - Lean back: system bars reappear on any touch (bad for us)
     *   - Immersive: system bars reappear on edge swipe (OK)
     *   - Immersive sticky: bars appear briefly on edge swipe, then auto-hide
     *
     * We use immersive sticky because:
     *   - Touch input should go to our SurfaceView, not show system bars
     *   - If the user intentionally swipes from the edge, they get a brief
     *     peek at the status bar, then it hides automatically
     *   - No accidental exits from fullscreen during normal stylus use
     *
     * # API 30+ (Android 11) WindowInsetsController
     *
     * The older View.setSystemUiVisibility() API is deprecated. The modern
     * replacement is WindowInsetsController, which provides the same
     * functionality with a cleaner API.
     */
    private fun hideSystemUi() {
        // Use the modern WindowInsetsController API (API 30+)
        // Our minSdk is 28, so we check the API level.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                // Hide both the status bar and navigation bar
                controller.hide(
                    WindowInsets.Type.statusBars() or
                    WindowInsets.Type.navigationBars()
                )

                // BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE = immersive sticky mode
                // The bars peek when the user swipes, then auto-hide after ~3 seconds
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            // Fallback for API 28-29: use the deprecated setSystemUiVisibility
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            )
        }
    }
}
