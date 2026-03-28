## ADDED Requirements

### Requirement: ADB Reverse Tunnel

The system SHALL set up an ADB reverse tunnel from the Boox device to the Mac host for frame delivery. The tunnel maps a TCP port on the device to a TCP port on the host, allowing the Android app to connect to localhost:devicePort and reach the Mac's frame server. The implementation must load shell environment variables (ANDROID_HOME, PATH) from the user's shell profile to locate the adb binary.

**Acceptance Criteria:**
- Executes `adb reverse tcp:<devicePort> tcp:<hostPort>` successfully
- Loads ANDROID_HOME and PATH from user's shell profile (~/.zshrc, ~/.bash_profile)
- Returns success/failure with descriptive error messages
- Handles already-connected device gracefully
- Detects when ADB is not installed and provides actionable error

#### Scenario: First connection
**Given** a Boox device is connected via USB and ADB is installed
**When** setupReverseTunnel(devicePort: 9876, hostPort: 9876) is called
**Then** `adb reverse tcp:9876 tcp:9876` succeeds, and the device can reach host port 9876 via localhost:9876

#### Scenario: Device already connected
**Given** an ADB reverse tunnel is already active on port 9876
**When** setupReverseTunnel(devicePort: 9876, hostPort: 9876) is called again
**Then** the existing tunnel is reused or cleanly replaced without error

#### Scenario: ADB not found
**Given** ADB is not installed or not in PATH
**When** setupReverseTunnel is called
**Then** a clear error is returned: "ADB not found. Install Android SDK Platform Tools or set ANDROID_HOME."

#### Scenario: Device unplugged
**Given** no USB device is connected
**When** setupReverseTunnel is called
**Then** a clear error is returned: "No device found. Connect your Boox tablet via USB."

**Cross-references:** `app-shell`

---

### Requirement: Binary Protocol

The transport layer MUST implement a length-prefixed binary protocol for frame delivery. Each message starts with an 11-byte header followed by the payload. The header structure is:

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 2 | magic | 0xE1CE (constant) |
| 2 | 1 | flags | bit 0: keyframe, bit 1: color mode, bits 2-7: reserved |
| 3 | 4 | sequence | monotonically increasing frame number |
| 7 | 4 | length | payload size in bytes (big-endian) |

**Acceptance Criteria:**
- Header is exactly 11 bytes
- Magic bytes are 0xE1CE
- Flags encode keyframe and color mode
- Sequence number increments per frame
- Length field matches actual payload size
- Big-endian byte order for multi-byte fields

#### Scenario: Normal delta frame
**Given** a compressed delta payload of 1500 bytes, frame sequence 42
**When** the frame is serialized
**Then** header is [0xE1, 0xCE, 0x00, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x05, 0xDC] followed by 1500 bytes of payload

#### Scenario: Keyframe
**Given** a compressed keyframe payload, frame sequence 100
**When** the frame is serialized with keyframe flag
**Then** flags byte is 0x01 (bit 0 set), and the payload contains the full compressed frame

#### Scenario: Color mode frame
**Given** a compressed color frame payload
**When** the frame is serialized with color mode flag
**Then** flags byte is 0x02 (bit 1 set), indicating the receiver should use color rendering path

#### Scenario: Maximum payload size
**Given** a payload at the maximum supported size (16 MB)
**When** the frame is serialized
**Then** the length field correctly encodes the size in big-endian, and the receiver can parse and allocate appropriately

**Cross-references:** `delta-encoding`, `image-pipeline`

---

### Requirement: Bidirectional Multiplexing

The transport layer MUST multiplex frame data (Mac to Boox) and input events (Boox to Mac) on the same ADB reverse tunnel connection. Frame data flows as the primary stream; input events flow as a secondary stream interleaved using a channel byte prefix (0x01 for frames, 0x02 for input).

**Acceptance Criteria:**
- Single TCP connection carries both frame and input data
- Channel byte 0x01 prefixes frame messages
- Channel byte 0x02 prefixes input event messages
- Input events are not blocked by frame transmission
- Both channels can be active simultaneously

#### Scenario: Simultaneous frame and input
**Given** the Mac is sending a frame while the Boox is sending a stylus event
**When** both messages are in-flight
**Then** each message is correctly demultiplexed by its channel prefix, frame arrives intact, and input event arrives intact

#### Scenario: Input-only (idle screen)
**Given** the screen is idle (no frames being sent)
**When** the user draws with the stylus on the Boox
**Then** input events flow freely over channel 0x02 with minimal latency (<5ms added by transport)

#### Scenario: Frame-only (no input)
**Given** no stylus or touch input is occurring
**When** frames are being streamed
**Then** frames flow over channel 0x01 without interference, and the input channel remains idle

**Cross-references:** `stylus-input`

---

### Requirement: Auto-Reconnection

The system MUST detect USB disconnect and automatically re-establish the ADB reverse tunnel with exponential backoff. After reconnection, restore state by sending a keyframe and resynchronizing settings.

**Acceptance Criteria:**
- Detects connection loss within 2 seconds
- Retries with exponential backoff: 1s, 2s, 4s, 8s, max 30s
- Sends keyframe immediately after reconnect
- Resynchronizes settings (mode, resolution) after reconnect
- Emits status events for UI updates (connecting, connected, disconnected)

#### Scenario: Clean disconnect
**Given** mirroring is active
**When** the user unplugs the USB cable cleanly
**Then** connection loss is detected within 2 seconds, status changes to "disconnected", and reconnection attempts begin at 1s intervals with exponential backoff

#### Scenario: Sudden unplug
**Given** mirroring is active and a frame is mid-transfer
**When** the USB cable is suddenly pulled
**Then** the broken write is detected, partial data is discarded, status changes to "disconnected", and reconnection begins

#### Scenario: Reconnect with state restoration
**Given** the device was disconnected and is now plugged back in
**When** the ADB tunnel is re-established
**Then** a full keyframe is sent as the first frame, current settings (mode, resolution, contrast, sharpening) are re-sent, and mirroring resumes seamlessly

**Cross-references:** `delta-encoding`, `app-shell`

---

### Requirement: Backpressure

The transport layer MUST monitor round-trip time (RTT) via ACK packets from the Boox device and adaptively drop frames when the client cannot keep up. This prevents unbounded buffer growth and ensures the display always shows a recent frame rather than queuing stale frames.

**Acceptance Criteria:**
- Boox sends a 4-byte ACK (sequence number) after rendering each frame
- Mac tracks RTT per frame
- If RTT exceeds 2x the target frame interval, subsequent frames are dropped until an ACK is received
- Frame drop events are logged for diagnostics
- Recovery: resume full frame rate once RTT normalizes

#### Scenario: Normal latency
**Given** RTT is consistently under 50ms
**When** frames are being streamed at 5fps
**Then** all frames are delivered without drops, and ACKs arrive in sequence

#### Scenario: High latency (drop frames)
**Given** RTT spikes to 500ms (device is busy with GC refresh)
**When** new frames are ready to send
**Then** frames are dropped (not queued) until an ACK for the last sent frame is received, then the latest frame is sent

#### Scenario: Recovery after congestion
**Given** frames were being dropped due to high RTT
**When** RTT returns to normal (<100ms)
**Then** frame delivery resumes at the normal adaptive rate within 2 frame intervals

**Cross-references:** `screen-capture`, `eink-renderer`
