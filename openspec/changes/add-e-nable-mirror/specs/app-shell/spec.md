## ADDED Requirements

### Requirement: Menu Bar App

The application SHALL provide a macOS menu bar interface showing real-time connection status with a color-coded icon badge. The menu bar provides quick access to common controls and settings without opening a full window.

**Acceptance Criteria:**
- Menu bar icon with color-coded status badge
- Grey badge: idle (not connected)
- Yellow badge: connecting (tunnel being established)
- Green badge: mirroring (actively streaming frames)
- Red badge: error (connection failed, device not found)
- Dropdown menu with controls: Start/Stop, Mode toggle, Settings, Quit
- Status text in dropdown shows current resolution, mode, and FPS

#### Scenario: Idle state (grey badge)
**Given** the app is launched but no device is connected
**When** the menu bar icon is displayed
**Then** the badge is grey, and the dropdown shows "Idle -- No device connected"

#### Scenario: Connecting state (yellow badge)
**Given** the user clicks "Start" or a device is detected
**When** the ADB tunnel is being established
**Then** the badge turns yellow, and the dropdown shows "Connecting..."

#### Scenario: Mirroring state (green badge)
**Given** the ADB tunnel is established and frames are streaming
**When** mirroring is active
**Then** the badge turns green, and the dropdown shows "Mirroring -- 1240x930 B&W @ 5fps"

#### Scenario: Error state (red badge)
**Given** a connection error occurs (ADB not found, device unplugged during mirror)
**When** the error is detected
**Then** the badge turns red, and the dropdown shows the error message with a suggested action

**Cross-references:** `transport`

---

### Requirement: CLI Interface

The application SHALL provide a command-line interface for controlling e-nable without the menu bar app, suitable for scripting and headless operation. The CLI communicates with a running instance via IPC or operates standalone.

**Acceptance Criteria:**
- `e-nable start` -- begin mirroring (connects to device, sets up tunnel, starts capture)
- `e-nable stop` -- stop mirroring gracefully
- `e-nable status` -- print current state (connected/disconnected, resolution, mode, FPS, latency)
- `e-nable config --mode bw|color` -- switch render mode
- `e-nable config --resolution <preset>` -- switch resolution preset (cozy, comfortable, balanced, sharp)
- Exit codes: 0 success, 1 error, 2 device not found
- JSON output available with `--json` flag

#### Scenario: Start mirroring
**Given** a Boox device is connected via USB
**When** `e-nable start` is executed
**Then** the ADB tunnel is established, virtual display is created, frame capture begins, and "Mirroring started at 1240x930 B&W" is printed to stdout

#### Scenario: Stop mirroring
**Given** mirroring is currently active
**When** `e-nable stop` is executed
**Then** frame capture stops, virtual display is removed, ADB tunnel is closed, and "Mirroring stopped" is printed

#### Scenario: Query status
**Given** mirroring is active at 1240x930 in B&W mode at 5fps
**When** `e-nable status` is executed
**Then** output shows: "Status: Mirroring\nResolution: 1240x930 (balanced)\nMode: B&W\nFPS: 5\nLatency: 23ms"

#### Scenario: Change render mode
**Given** mirroring is active in B&W mode
**When** `e-nable config --mode color` is executed
**Then** the pipeline switches to color mode, "Mode changed to Color" is printed, and subsequent frames use color processing

#### Scenario: Change resolution
**Given** mirroring is active at balanced (1240x930)
**When** `e-nable config --resolution sharp` is executed
**Then** the virtual display is recreated at 2480x1860, "Resolution changed to sharp (2480x1860)" is printed, and mirroring resumes

**Cross-references:** `screen-capture`, `image-pipeline`, `transport`

---

### Requirement: Settings Management

The application MUST persist user settings to disk so preferences are remembered across launches. Settings include display and image processing parameters that affect the mirroring experience.

**Acceptance Criteria:**
- Settings stored in ~/Library/Application Support/e-nable/settings.json
- Persisted settings: resolution (preset name), mode (bw/color), brightness (0-100), warmth (0-100), sharpening (0.0-3.0), contrast/gamma (0.5-3.0), ghost-clear interval (number of frames)
- Settings loaded on app launch
- Settings saved immediately on change
- Reset to defaults available via CLI (`e-nable config --reset`) and menu

#### Scenario: Save settings
**Given** the user changes sharpening to 2.0 via CLI or menu
**When** the setting is applied
**Then** settings.json is updated with "sharpening": 2.0 and the image pipeline uses the new value immediately

#### Scenario: Load settings on launch
**Given** settings.json exists with custom values (mode: "color", resolution: "sharp")
**When** the app launches
**Then** mirroring starts with color mode at sharp resolution, matching the persisted settings

#### Scenario: Reset to defaults
**Given** settings.json has custom values
**When** `e-nable config --reset` is executed
**Then** all settings are restored to defaults (resolution: balanced, mode: bw, brightness: 50, warmth: 0, sharpening: 1.5, contrast: 1.2, ghost-clear: 30) and settings.json is overwritten

**Cross-references:** `image-pipeline`, `eink-renderer`

---

### Requirement: IPC via Unix Socket

The menu bar app and CLI MUST communicate via a Unix domain socket for real-time control and status updates. This allows the CLI to control a running GUI instance and vice versa.

**Acceptance Criteria:**
- Unix domain socket at /tmp/e-nable.sock
- Protocol: newline-delimited JSON messages
- Commands: start, stop, status, config (with parameters)
- Status file at /tmp/e-nable.status updated every 5 seconds with current state
- Multiple CLI instances can connect simultaneously
- Socket is cleaned up on app exit

#### Scenario: CLI controls running GUI
**Given** the menu bar app is running and mirroring
**When** `e-nable stop` is executed from the CLI
**Then** the CLI sends {"command": "stop"} to the socket, the GUI stops mirroring, and the CLI receives {"status": "ok", "message": "Mirroring stopped"}

#### Scenario: Status file updates
**Given** mirroring is active
**When** 5 seconds pass
**Then** /tmp/e-nable.status is updated with JSON containing: state, resolution, mode, fps, latency, uptime, and frames_sent

#### Scenario: Multiple CLI instances
**Given** the menu bar app is running
**When** two CLI instances simultaneously send "status" queries
**Then** both receive correct status responses without interference or deadlock

**Cross-references:** `transport`

---

### Requirement: Keyboard Shortcuts

The application SHALL provide global keyboard shortcuts for common mirroring operations. Shortcuts work regardless of which app is in the foreground, using macOS global hotkey registration.

**Acceptance Criteria:**
- Ctrl+F1: decrease brightness by 10
- Ctrl+F2: increase brightness by 10
- Ctrl+F8: toggle mirroring on/off
- Shortcuts registered globally (work from any app)
- Shortcuts are configurable in settings
- Conflict detection with existing system shortcuts

#### Scenario: Toggle mirroring
**Given** mirroring is currently active
**When** the user presses Ctrl+F8
**Then** mirroring stops, the menu bar badge turns grey, and pressing Ctrl+F8 again restarts mirroring

#### Scenario: Adjust brightness
**Given** mirroring is active with brightness at 50
**When** the user presses Ctrl+F2
**Then** brightness increases to 60, the setting is persisted, and the next frame reflects the brightness change

#### Scenario: Switch mode
**Given** mirroring is active in B&W mode
**When** the user presses the configured mode-switch shortcut
**Then** mode toggles to Color, the pipeline switches, and the menu bar status updates

**Cross-references:** `image-pipeline`, `screen-capture`
