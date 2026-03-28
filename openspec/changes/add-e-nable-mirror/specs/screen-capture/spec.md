## ADDED Requirements

### Requirement: Virtual Display Creation

The system SHALL create a virtual display at Boox-native resolutions using the CGVirtualDisplay private API. The virtual display acts as a real secondary monitor in macOS, allowing any window to be dragged onto it for mirroring. Creation must be idempotent -- if a virtual display already exists with the requested resolution, reuse it rather than creating a duplicate.

**Acceptance Criteria:**
- Virtual display appears in System Preferences > Displays
- Supports 1240x930 (Boox Tab Ultra C color native) and 2480x1860 (B&W 2x) resolutions
- Supports custom arbitrary resolutions
- Calling create when display already exists returns the existing display without error

#### Scenario: Create virtual display at 1240x930 (color mode)
**Given** no virtual display currently exists
**When** createVirtualDisplay(width: 1240, height: 930) is called
**Then** a new CGVirtualDisplay is created at 1240x930, appears in macOS display list, and returns a valid display ID

#### Scenario: Create virtual display at 2480x1860 (B&W HiDPI)
**Given** no virtual display currently exists
**When** createVirtualDisplay(width: 2480, height: 1860) is called
**Then** a new CGVirtualDisplay is created at 2480x1860 and returns a valid display ID

#### Scenario: Create virtual display with custom resolution
**Given** no virtual display currently exists
**When** createVirtualDisplay(width: 1024, height: 768) is called
**Then** a new CGVirtualDisplay is created at 1024x768 and returns a valid display ID

#### Scenario: Idempotent creation when display already exists
**Given** a virtual display already exists at 1240x930
**When** createVirtualDisplay(width: 1240, height: 930) is called again
**Then** the existing display is returned without creating a duplicate, and the display ID matches the original

**Cross-references:** `image-pipeline`, `app-shell`

---

### Requirement: Frame Acquisition

The system MUST acquire raw BGRA pixel buffers via CGDisplayStream at the virtual display's native resolution. Each frame callback delivers an IOSurface-backed buffer suitable for GPU or CPU processing. The cursor must be composited into the frame. The system must recover gracefully from display sleep/wake cycles.

**Acceptance Criteria:**
- Frames delivered as BGRA pixel buffers at native resolution
- Hardware cursor is rendered into the captured frame
- Frame delivery resumes automatically after display sleep/wake
- Frame callback jitter is <2ms under normal load

#### Scenario: Steady-state frame delivery
**Given** a virtual display exists and CGDisplayStream is running
**When** content on the virtual display changes
**Then** a frame callback fires with a BGRA pixel buffer matching the display resolution, and the buffer stride matches width * 4 bytes

#### Scenario: Cursor rendering included
**Given** CGDisplayStream is capturing frames
**When** the mouse cursor is positioned over the virtual display
**Then** the captured frame includes the rendered cursor at the correct position

#### Scenario: Display sleep/wake recovery
**Given** CGDisplayStream is capturing frames
**When** the Mac enters sleep and then wakes
**Then** frame delivery resumes within 1 second of wake without requiring manual restart

#### Scenario: Frame callback jitter under 2ms
**Given** CGDisplayStream is capturing frames at steady state
**When** 100 consecutive frame callbacks are measured
**Then** the standard deviation of inter-frame intervals is <2ms

**Cross-references:** `image-pipeline`, `delta-encoding`

---

### Requirement: Resolution Presets

The system SHALL support predefined resolution presets that map friendly names to specific pixel dimensions. Lower presets use HiDPI 2x scaling so text remains sharp at smaller logical resolutions.

**Acceptance Criteria:**
- Preset "cozy" maps to 800x600
- Preset "comfortable" maps to 1024x768
- Preset "balanced" maps to 1240x930
- Preset "sharp" maps to 2480x1860
- Resolution can be switched at runtime without restarting
- Lower presets (cozy, comfortable) use HiDPI 2x backing to maintain text sharpness

#### Scenario: Switch resolution at runtime
**Given** mirroring is active at "balanced" (1240x930)
**When** the user selects "sharp" (2480x1860)
**Then** the virtual display is recreated at the new resolution, CGDisplayStream is restarted, and mirroring resumes within 500ms

#### Scenario: Verify aspect ratio maintained
**Given** any resolution preset is selected
**When** the virtual display is created
**Then** the pixel aspect ratio matches the preset exactly (no stretching or letterboxing)

#### Scenario: HiDPI 2x scaling for lower presets
**Given** the "cozy" preset (800x600) is selected
**When** the virtual display is created
**Then** it is configured with a 2x scale factor, backing store is 1600x1200 pixels, and logical resolution is 800x600 points

**Cross-references:** `app-shell`, `eink-renderer`

---

### Requirement: Adaptive Frame Rate

The system MUST limit frame capture rate based on e-ink display capability. E-ink panels cannot refresh faster than their hardware limit, so capturing excess frames wastes CPU, memory, and bandwidth. The capture rate adapts to screen activity level.

**Acceptance Criteria:**
- No frames captured when screen content is static (idle)
- Active typing produces ~5fps effective capture rate
- Rapid scrolling is capped at the display's maximum refresh rate
- Frame rate adjusts dynamically based on change detection

#### Scenario: Idle screen (no changes)
**Given** mirroring is active and screen content is completely static
**When** 5 seconds pass with no pixel changes
**Then** zero frames are captured and zero bytes are sent over transport

#### Scenario: Active typing (~5fps effective)
**Given** the user is typing in a text editor on the virtual display
**When** frame capture is running
**Then** approximately 5 frames per second are captured and delivered (within +/-1fps)

#### Scenario: Rapid scrolling capped at display rate
**Given** the user is rapidly scrolling a webpage
**When** the content changes every frame at 60fps
**Then** frame capture is capped at the e-ink display's maximum refresh rate (e.g., 12fps for GU mode) and excess frames are dropped

**Cross-references:** `transport`

---

### Requirement: CompositorPacer

The CompositorPacer MUST force the macOS compositor to redraw at 60Hz even when no visible UI changes occur. This uses a 4x4 pixel window that toggles between black (#000000) and an imperceptible near-black (#010000) to trick the compositor into continuous redraws. Without this, macOS may throttle rendering on the virtual display.

**Acceptance Criteria:**
- 4x4 pacer window is created and positioned off-screen or on the virtual display
- Window alternates fill color every frame at 60Hz
- Pacer starts automatically when mirroring begins
- Pacer stops when mirroring stops
- Color toggle is imperceptible to users

#### Scenario: Pacer active during mirroring
**Given** mirroring has started
**When** the CompositorPacer is running
**Then** a 4x4 window toggles between #000000 and #010000 at 60Hz, and CGDisplayStream receives consistent frame callbacks

#### Scenario: Pacer stopped when mirroring stops
**Given** mirroring is active with the pacer running
**When** mirroring is stopped via CLI or menu bar
**Then** the pacer window is destroyed and no further color toggles occur

#### Scenario: Verify 60Hz redraw rate
**Given** the CompositorPacer is active
**When** frame callback frequency is measured over 10 seconds
**Then** the average callback rate is 60fps +/-2fps

**Cross-references:** `app-shell`
