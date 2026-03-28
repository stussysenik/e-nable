/* ==========================================================================
 * mirror.js — WebSocket client + canvas renderer for e-ink screen mirroring
 * ==========================================================================
 *
 * Architecture overview:
 *
 *   Mac capture (Swift) --TCP--> Elixir server --WebSocket--> This client
 *
 * The server captures the Mac screen, compresses frames, and sends them
 * over a raw WebSocket as binary messages. This client:
 *
 *   1. Connects via raw WebSocket (not Phoenix Channels — we need binary)
 *   2. Parses the binary frame protocol (header + pixel data)
 *   3. Renders frames to a <canvas> using ImageData
 *   4. Sends touch/stylus input back as JSON messages
 *
 * Why raw WebSocket instead of Phoenix Channels?
 *   Phoenix Channels use a JSON-based protocol on top of WebSocket.
 *   Our frame data is binary (greyscale pixels), and wrapping binary
 *   in JSON (base64) would add ~33% overhead. Raw WebSocket lets us
 *   send ArrayBuffer directly with zero encoding overhead.
 *
 * E-ink optimization notes:
 *   - We never animate the UI — all changes are instantaneous
 *   - The canvas uses image-rendering: pixelated for sharp scaling
 *   - Touch input uses the Pointer Events API for stylus pressure/tilt
 *   - We batch requestAnimationFrame to avoid tearing
 * ========================================================================== */

(function () {
  "use strict";

  /* ========================================================================
   * CONSTANTS
   * ======================================================================== */

  /**
   * Binary frame protocol — Magic bytes and header layout.
   *
   * Every binary message from the server starts with this header:
   *
   *   Offset  Size  Field       Description
   *   ------  ----  ----------  -----------
   *   0       2     magic       0xDA 0x7E — identifies a valid frame
   *   2       1     flags       Bit 0: 0=delta, 1=keyframe
   *   3       4     seq         Sequence number (little-endian uint32)
   *   7       2     width       Frame width in pixels (LE uint16)
   *   9       2     height      Frame height in pixels (LE uint16)
   *   11      ...   payload     Greyscale pixel data
   *
   * For keyframes: payload is width*height bytes, one byte per pixel (grey).
   * For deltas: payload is the XOR difference from the previous keyframe.
   */
  var MAGIC_0 = 0xda;
  var MAGIC_1 = 0x7e;
  var HEADER_SIZE = 11;

  var FLAG_KEYFRAME = 0x01; // Bit 0 of flags byte

  /** How long (ms) the toolbar stays visible after user interaction. */
  var TOOLBAR_HIDE_DELAY = 5000;

  /** WebSocket reconnection delay (ms). Starts here, backs off exponentially. */
  var RECONNECT_BASE_MS = 1000;
  var RECONNECT_MAX_MS = 10000;

  /* ========================================================================
   * DOM REFERENCES
   * ======================================================================== */

  var canvas = document.getElementById("mirror-canvas");
  var ctx = canvas.getContext("2d", {
    /*
     * willReadFrequently: true
     *   Tells the browser we will call getImageData() on every frame.
     *   Without this hint, Chrome allocates the canvas on the GPU and
     *   has to do an expensive GPU→CPU readback each time we read pixels.
     *   With the hint, it keeps the canvas in CPU memory — much faster
     *   for our read-modify-write pattern (needed for XOR delta apply).
     */
    willReadFrequently: true,
  });

  var toolbar = document.querySelector(".toolbar");
  var statusDot = document.getElementById("status-dot");
  var statusText = document.getElementById("status-text");
  var fpsDisplay = document.getElementById("fps-display");
  var resDisplay = document.getElementById("res-display");
  var fullscreenBtn = document.getElementById("fullscreen-btn");
  var connectOverlay = document.querySelector(".connect-overlay");
  var overlayStatus = document.getElementById("overlay-status");
  var overlayInfo = document.getElementById("overlay-info");

  /* ========================================================================
   * STATE
   * ======================================================================== */

  var ws = null; // WebSocket instance
  var reconnectDelay = RECONNECT_BASE_MS;
  var reconnectTimer = null;

  /**
   * We keep the current frame's ImageData around so we can XOR-apply
   * delta frames onto it without re-reading from the canvas each time.
   * This is both faster and avoids potential color-space issues with
   * repeated getImageData/putImageData round-trips.
   */
  var currentImageData = null;
  var frameWidth = 0;
  var frameHeight = 0;

  /** FPS tracking — we count frames in a sliding 1-second window. */
  var frameTimestamps = [];
  var lastFps = 0;

  /** The most recently received frame, waiting to be painted on next rAF. */
  var pendingFrame = null;

  /** Toolbar auto-hide timer. */
  var toolbarTimer = null;
  var toolbarVisible = true;

  /** Last known sequence number for detecting dropped frames. */
  var lastSeq = -1;
  var frameCount = 0;

  /* ========================================================================
   * WEBSOCKET CONNECTION
   * ======================================================================== */

  /**
   * Establishes a raw WebSocket connection to the mirror endpoint.
   *
   * Why location.host?
   *   The WebSocket server runs on the same host:port as the HTTP server
   *   that served this page. Using location.host means this works in
   *   development (localhost:4000) and production without config changes.
   *
   * Why binaryType = 'arraybuffer'?
   *   WebSocket can deliver binary data as either Blob or ArrayBuffer.
   *   ArrayBuffer gives us synchronous access to the bytes via DataView
   *   and typed arrays — essential for our frame parsing. Blob would
   *   require an async FileReader, adding latency to every frame.
   */
  function connect() {
    setStatus("connecting");

    // Determine WebSocket protocol based on page protocol (http→ws, https→wss)
    var protocol = location.protocol === "https:" ? "wss:" : "ws:";
    var url = protocol + "//" + location.host + "/ws/mirror";

    ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";

    ws.onopen = function () {
      console.log("[mirror] WebSocket connected");
      setStatus("connected");
      reconnectDelay = RECONNECT_BASE_MS; // Reset backoff on successful connect

      // Send initial settings so the server knows our preferences
      sendJSON({
        type: "settings",
        mode: "greyscale",
        resolution: "balanced",
        viewport: {
          width: window.innerWidth,
          height: window.innerHeight,
          dpr: window.devicePixelRatio || 1,
        },
      });
    };

    ws.onclose = function (event) {
      console.log("[mirror] WebSocket closed:", event.code, event.reason);
      setStatus("disconnected");
      scheduleReconnect();
    };

    ws.onerror = function (event) {
      console.error("[mirror] WebSocket error:", event);
      // onclose will fire after onerror, which handles reconnection
    };

    /**
     * Handle incoming messages.
     *
     * Binary messages (ArrayBuffer) are frames from the capture pipeline.
     * String messages are JSON control messages from the server.
     */
    ws.onmessage = function (event) {
      if (event.data instanceof ArrayBuffer) {
        handleBinaryFrame(event.data);
      } else if (typeof event.data === "string") {
        handleJsonMessage(event.data);
      }
    };
  }

  /**
   * Exponential backoff reconnection.
   *
   * Each failed attempt doubles the delay (capped at RECONNECT_MAX_MS).
   * This prevents hammering the server when it's down and gives it
   * breathing room to recover.
   */
  function scheduleReconnect() {
    if (reconnectTimer) return; // Already scheduled

    console.log(
      "[mirror] Reconnecting in " + reconnectDelay + "ms..."
    );

    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      connect();
    }, reconnectDelay);

    // Exponential backoff: 1s → 2s → 4s → 8s → 10s (capped)
    reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
  }

  /** Send a JSON message to the server. Silently drops if not connected. */
  function sendJSON(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    }
  }

  /* ========================================================================
   * BINARY FRAME PARSING
   * ======================================================================== */

  /**
   * Parse and process a binary frame message.
   *
   * Frame layout (see CONSTANTS section above for field details):
   *
   *   [0xDA 0x7E] [flags:1] [seq:4 LE] [width:2 LE] [height:2 LE] [payload...]
   *
   * The payload is greyscale pixel data:
   *   - Keyframe: raw grey values, one byte per pixel (width * height bytes)
   *   - Delta: XOR difference from previous frame
   *
   * We don't render immediately — instead we store the parsed frame in
   * `pendingFrame` and let requestAnimationFrame pick it up. This ensures
   * we paint in sync with the display's vsync and avoids tearing.
   *
   * @param {ArrayBuffer} buffer - Raw binary message from WebSocket
   */
  function handleBinaryFrame(buffer) {
    /*
     * DataView lets us read multi-byte integers with explicit endianness.
     * Our protocol uses little-endian (LE), which matches x86/ARM native
     * byte order — the server can write integers directly without swapping.
     */
    var view = new DataView(buffer);

    // Validate minimum size
    if (buffer.byteLength < HEADER_SIZE) {
      console.warn("[mirror] Frame too small:", buffer.byteLength, "bytes");
      return;
    }

    // Check magic bytes — guards against corrupted or misrouted messages
    if (view.getUint8(0) !== MAGIC_0 || view.getUint8(1) !== MAGIC_1) {
      console.warn("[mirror] Bad magic bytes, ignoring frame");
      return;
    }

    var flags = view.getUint8(2);
    var seq = view.getUint32(3, true); // true = little-endian
    var width = view.getUint16(7, true);
    var height = view.getUint16(9, true);

    var isKeyframe = (flags & FLAG_KEYFRAME) !== 0;

    // Debug: log first frame and every 30th frame
    if (frameCount === 0 || frameCount % 30 === 0) {
      console.log("[mirror] Frame #" + seq + ": " + width + "x" + height +
        (isKeyframe ? " KEYFRAME" : " delta") +
        " payload=" + (buffer.byteLength - HEADER_SIZE) + " bytes" +
        " total=" + buffer.byteLength + " bytes");
    }
    frameCount++;

    /*
     * Extract payload as a Uint8Array view into the original buffer.
     * No copy happens here — Uint8Array just points into the ArrayBuffer.
     * This is important for large frames (e.g., 2480*1860 = 4.6MB).
     */
    var payload = new Uint8Array(buffer, HEADER_SIZE);

    // Detect dropped frames (gaps in sequence numbers)
    if (lastSeq >= 0 && seq !== lastSeq + 1 && seq !== 0) {
      console.warn(
        "[mirror] Sequence gap: expected " + (lastSeq + 1) + ", got " + seq
      );
    }
    lastSeq = seq;

    // Store for rAF to pick up (overwrites any un-rendered previous frame)
    pendingFrame = {
      isKeyframe: isKeyframe,
      width: width,
      height: height,
      payload: payload,
    };

    // Request a render on next vsync
    requestAnimationFrame(renderFrame);
  }

  /** Handle JSON control messages from the server. */
  function handleJsonMessage(data) {
    try {
      var msg = JSON.parse(data);
      console.log("[mirror] Server message:", msg);

      // Future: handle server-side settings changes, error messages, etc.
    } catch (e) {
      console.warn("[mirror] Invalid JSON from server:", data);
    }
  }

  /* ========================================================================
   * FRAME RENDERING
   * ======================================================================== */

  /**
   * Render the pending frame to the canvas.
   *
   * Called via requestAnimationFrame, which ensures we paint exactly once
   * per display refresh. If multiple frames arrive between repaints
   * (server sending faster than display refresh rate), we only render
   * the latest one — this is intentional for e-ink where fewer, complete
   * updates are better than many partial ones.
   *
   * Canvas ImageData layout:
   *   The canvas 2D API stores pixels as a flat Uint8ClampedArray in
   *   RGBA order: [R0, G0, B0, A0, R1, G1, B1, A1, ...].
   *   Each channel is 0-255. For greyscale, we set R=G=B=grey, A=255.
   */
  function renderFrame() {
    if (!pendingFrame) return;

    var frame = pendingFrame;
    pendingFrame = null;

    // If canvas size changed, resize it to match the incoming frame
    if (frame.width !== frameWidth || frame.height !== frameHeight) {
      resizeCanvas(frame.width, frame.height);
    }

    if (frame.isKeyframe) {
      applyKeyframe(frame.payload);
    } else {
      applyDelta(frame.payload);
    }

    // Paint the ImageData to the canvas
    ctx.putImageData(currentImageData, 0, 0);

    // Hide the connection overlay once we have our first frame
    if (connectOverlay && !connectOverlay.classList.contains("connect-overlay--hidden")) {
      connectOverlay.classList.add("connect-overlay--hidden");
    }

    // Track FPS
    recordFrame();
  }

  /**
   * Resize the canvas to match incoming frame dimensions.
   *
   * Important: setting canvas.width/height clears the canvas AND resets
   * the 2D context state (transforms, styles, etc.). We also need to
   * create a fresh ImageData buffer at the new size.
   *
   * We set the CSS size to maintain aspect ratio within the viewport
   * while the canvas resolution matches the actual pixel data.
   */
  function resizeCanvas(width, height) {
    canvas.width = width;
    canvas.height = height;
    frameWidth = width;
    frameHeight = height;

    // Create a fresh ImageData buffer, initialized to black (all zeros)
    currentImageData = ctx.createImageData(width, height);

    /*
     * Initialize alpha channel to 255 (fully opaque).
     * createImageData initializes all bytes to 0, which means transparent.
     * We need opaque pixels so the canvas isn't see-through.
     */
    var data = currentImageData.data;
    for (var i = 3; i < data.length; i += 4) {
      data[i] = 255;
    }

    // Update resolution display
    if (resDisplay) {
      resDisplay.textContent = width + "x" + height;
    }

    console.log("[mirror] Canvas resized to " + width + "x" + height);
  }

  /**
   * Apply a keyframe — replace the entire canvas contents.
   *
   * Keyframes contain raw greyscale values, one byte per pixel.
   * We expand each grey byte into RGBA (R=G=B=grey, A=255).
   *
   * @param {Uint8Array} greyPixels - width*height greyscale values
   */
  function applyKeyframe(greyPixels) {
    var data = currentImageData.data;
    var pixelCount = Math.min(greyPixels.length, frameWidth * frameHeight);

    for (var i = 0; i < pixelCount; i++) {
      var grey = greyPixels[i];
      var offset = i * 4;
      data[offset] = grey;     // R
      data[offset + 1] = grey; // G
      data[offset + 2] = grey; // B
      // data[offset + 3] stays 255 (alpha, set during resize)
    }
  }

  /**
   * Apply a delta frame — XOR the difference onto the current image.
   *
   * Delta compression works by XOR-ing the current frame with the previous:
   *   delta[i] = current[i] XOR previous[i]
   *
   * To reconstruct the current frame from the previous + delta:
   *   current[i] = previous[i] XOR delta[i]
   *
   * Why XOR?
   *   - Symmetric: A XOR B XOR B = A (self-inverse)
   *   - Unchanged pixels produce 0x00 in the delta (compresses well)
   *   - No overflow/underflow — stays in 0-255 range
   *   - Single CPU instruction, extremely fast
   *
   * The delta is computed on greyscale values. We XOR against the R channel
   * of our RGBA ImageData (R=G=B for greyscale, so any channel works).
   *
   * @param {Uint8Array} deltaBytes - XOR delta, one byte per pixel
   */
  function applyDelta(deltaBytes) {
    var data = currentImageData.data;
    var pixelCount = Math.min(deltaBytes.length, frameWidth * frameHeight);

    for (var i = 0; i < pixelCount; i++) {
      var offset = i * 4;
      // XOR the existing grey value with the delta byte
      var grey = data[offset] ^ deltaBytes[i];
      data[offset] = grey;     // R
      data[offset + 1] = grey; // G
      data[offset + 2] = grey; // B
      // Alpha stays 255
    }
  }

  /* ========================================================================
   * FPS TRACKING
   * ======================================================================== */

  /**
   * Simple frame rate counter using a sliding window.
   *
   * We store the timestamp of each rendered frame and count how many
   * fall within the last 1000ms. This gives a smooth, accurate FPS
   * reading without the jitter of measuring individual frame intervals.
   */
  function recordFrame() {
    var now = performance.now();
    frameTimestamps.push(now);

    // Prune timestamps older than 1 second
    while (frameTimestamps.length > 0 && frameTimestamps[0] < now - 1000) {
      frameTimestamps.shift();
    }

    var fps = frameTimestamps.length;

    // Only update DOM when FPS changes to avoid unnecessary e-ink refreshes
    if (fps !== lastFps) {
      lastFps = fps;
      if (fpsDisplay) {
        fpsDisplay.textContent = fps + " fps";
      }
    }
  }

  /* ========================================================================
   * INPUT CAPTURE — Touch & Stylus
   * ======================================================================== */

  /**
   * Pointer Events API — unified handling for mouse, touch, and stylus.
   *
   * Why Pointer Events instead of Touch Events?
   *   - Single API for all input types (mouse, finger, pen/stylus)
   *   - Provides pressure and tilt data for stylus (Boox has Wacom EMR)
   *   - Better browser support than the older Touch Events API
   *
   * We normalize coordinates to 0.0-1.0 range relative to the canvas.
   * The server maps these back to screen coordinates at the Mac's resolution.
   * This decouples the client from knowing the actual screen dimensions.
   */

  /**
   * Convert a PointerEvent to our input protocol and send it.
   *
   * @param {string} action - "down", "move", or "up"
   * @param {PointerEvent} event
   */
  function sendPointerInput(action, event) {
    // Normalize to 0.0-1.0 relative to canvas display size
    var rect = canvas.getBoundingClientRect();
    var x = (event.clientX - rect.left) / rect.width;
    var y = (event.clientY - rect.top) / rect.height;

    // Clamp to [0, 1] in case of edge rounding
    x = Math.max(0, Math.min(1, x));
    y = Math.max(0, Math.min(1, y));

    sendJSON({
      type: "input",
      action: action,
      x: x,
      y: y,
      /*
       * pressure: 0.0 to 1.0 (0 = no contact, 1 = max pressure)
       * Stylus pens report analog pressure; mouse/finger report 0.5 when down.
       * The Boox Wacom EMR stylus supports 4096 pressure levels via the API.
       */
      pressure: event.pressure || 0,
      /*
       * tiltX/tiltY: -90 to 90 degrees
       * Only available with stylus input. Useful for brush-like tools.
       */
      tiltX: event.tiltX || 0,
      tiltY: event.tiltY || 0,
      /*
       * pointerType: "mouse", "pen", or "touch"
       * Lets the server distinguish input sources.
       */
      tool: event.pointerType || "mouse",
      /*
       * Button state for right-click / barrel button on stylus.
       * 0=none, 1=primary, 2=secondary (barrel), 4=eraser
       */
      buttons: event.buttons || 0,
    });
  }

  /** Pointer event handlers — bound to the canvas in init(). */
  function onPointerDown(event) {
    event.preventDefault();

    /*
     * setPointerCapture ensures we receive pointermove and pointerup
     * even if the pointer leaves the canvas element. Essential for
     * drag operations that might overshoot the canvas bounds.
     */
    canvas.setPointerCapture(event.pointerId);
    sendPointerInput("down", event);
  }

  function onPointerMove(event) {
    // Only send moves while a button is pressed (dragging)
    if (event.pressure > 0) {
      event.preventDefault();
      sendPointerInput("move", event);
    }
  }

  function onPointerUp(event) {
    event.preventDefault();
    sendPointerInput("up", event);
  }

  /* ========================================================================
   * TOOLBAR MANAGEMENT
   * ======================================================================== */

  /**
   * Auto-hide the toolbar after TOOLBAR_HIDE_DELAY ms of inactivity.
   *
   * On e-ink, static UI elements cause burn-in-like image retention.
   * Hiding the toolbar when not in use keeps the display cleaner and
   * reduces the chance of ghosting artifacts.
   */
  function showToolbar() {
    if (!toolbarVisible) {
      toolbar.classList.remove("toolbar--hidden");
      toolbarVisible = true;
    }
    resetToolbarTimer();
  }

  function hideToolbar() {
    toolbar.classList.add("toolbar--hidden");
    toolbarVisible = false;
  }

  function resetToolbarTimer() {
    if (toolbarTimer) clearTimeout(toolbarTimer);
    toolbarTimer = setTimeout(hideToolbar, TOOLBAR_HIDE_DELAY);
  }

  /**
   * Update the connection status indicator.
   * @param {"connecting"|"connected"|"disconnected"} state
   */
  function setStatus(state) {
    // Update status dot CSS class
    statusDot.className = "status-dot status-dot--" + state;

    // Update text
    var labels = {
      connecting: "Connecting...",
      connected: "Connected",
      disconnected: "Disconnected",
    };
    statusText.textContent = labels[state] || state;

    // Update overlay if still visible
    if (overlayStatus) {
      overlayStatus.textContent = labels[state] || state;
    }
    if (overlayInfo) {
      if (state === "connecting") {
        overlayInfo.textContent = "Establishing WebSocket connection...";
      } else if (state === "disconnected") {
        overlayInfo.textContent = "Will reconnect automatically.";
      } else {
        overlayInfo.textContent = "Waiting for first frame...";
      }
    }
  }

  /* ========================================================================
   * FULLSCREEN
   * ======================================================================== */

  /**
   * Toggle fullscreen mode.
   *
   * Fullscreen is especially important for e-ink — the Boox browser chrome
   * takes up screen space and causes extra repaints when the URL bar
   * hides/shows. Fullscreen gives us the entire display.
   *
   * We use the standard Fullscreen API with webkit fallback for older
   * WebKit-based Boox browsers.
   */
  function toggleFullscreen() {
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      // Exit fullscreen
      if (document.exitFullscreen) {
        document.exitFullscreen();
      } else if (document.webkitExitFullscreen) {
        document.webkitExitFullscreen();
      }
    } else {
      // Enter fullscreen
      var el = document.documentElement;
      if (el.requestFullscreen) {
        el.requestFullscreen();
      } else if (el.webkitRequestFullscreen) {
        el.webkitRequestFullscreen();
      }
    }
  }

  /** Update fullscreen button text when state changes. */
  function onFullscreenChange() {
    var isFs = !!(document.fullscreenElement || document.webkitFullscreenElement);
    if (fullscreenBtn) {
      fullscreenBtn.textContent = isFs ? "[x] Exit FS" : "[ ] Fullscreen";
    }
  }

  /* ========================================================================
   * KEYBOARD SHORTCUTS
   * ======================================================================== */

  function onKeyDown(event) {
    switch (event.key) {
      case "f":
      case "F":
        // F = toggle fullscreen
        if (!event.ctrlKey && !event.metaKey) {
          toggleFullscreen();
        }
        break;

      case "t":
      case "T":
        // T = toggle toolbar visibility
        if (!event.ctrlKey && !event.metaKey) {
          if (toolbarVisible) {
            hideToolbar();
          } else {
            showToolbar();
          }
        }
        break;

      case "Escape":
        // Esc = show toolbar (useful if it was hidden)
        showToolbar();
        break;
    }
  }

  /* ========================================================================
   * WINDOW RESIZE
   * ======================================================================== */

  /**
   * Notify the server when the viewport changes.
   *
   * The server can use this to adjust the capture resolution or
   * downscale factor to match the client's display capabilities.
   * On Boox devices, this is especially important because the
   * native resolution (2480x1860) may differ from the browser's
   * reported viewport (which accounts for devicePixelRatio).
   */
  function onResize() {
    sendJSON({
      type: "settings",
      viewport: {
        width: window.innerWidth,
        height: window.innerHeight,
        dpr: window.devicePixelRatio || 1,
      },
    });
  }

  /* ========================================================================
   * INITIALIZATION
   * ======================================================================== */

  /**
   * Boot everything up.
   *
   * We use DOMContentLoaded to ensure the DOM is ready, but we don't
   * wait for images/styles (that would be the 'load' event). Since our
   * page has no images, DOMContentLoaded is sufficient and faster.
   */
  function init() {
    console.log("[mirror] Initializing e-ink mirror client");

    // --- Canvas input ---
    canvas.addEventListener("pointerdown", onPointerDown);
    canvas.addEventListener("pointermove", onPointerMove);
    canvas.addEventListener("pointerup", onPointerUp);
    canvas.addEventListener("pointercancel", onPointerUp);

    /*
     * Prevent context menu on long-press (common on touch devices).
     * We want long-press to be a sustained stylus input, not a menu.
     */
    canvas.addEventListener("contextmenu", function (e) {
      e.preventDefault();
    });

    // --- Toolbar interactions ---
    if (fullscreenBtn) {
      fullscreenBtn.addEventListener("click", function (e) {
        e.stopPropagation();
        toggleFullscreen();
      });
    }

    // Show toolbar on any tap/click in the bottom region
    document.addEventListener("click", function () {
      showToolbar();
    });

    // Keyboard shortcuts
    document.addEventListener("keydown", onKeyDown);

    // Fullscreen change listener
    document.addEventListener("fullscreenchange", onFullscreenChange);
    document.addEventListener("webkitfullscreenchange", onFullscreenChange);

    // Window resize
    window.addEventListener("resize", onResize);

    // Start toolbar auto-hide timer
    resetToolbarTimer();

    // --- Connect ---
    connect();

    console.log("[mirror] Ready. Keyboard shortcuts: F=fullscreen, T=toolbar, Esc=show toolbar");
  }

  // Boot when DOM is ready
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    // DOM already loaded (script at end of body or deferred)
    init();
  }
})();
