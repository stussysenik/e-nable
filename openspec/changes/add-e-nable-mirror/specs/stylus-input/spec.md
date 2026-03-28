## ADDED Requirements

### Requirement: Wacom EMR Capture

The system MUST capture Wacom EMR (Electro-Magnetic Resonance) digitizer events from the Boox Tab Ultra C's built-in stylus sensor. The digitizer provides high-resolution position, 4096 levels of pressure, and tilt data. Events must be distinguished from capacitive touch using Android's MotionEvent.getToolType().

**Acceptance Criteria:**
- Captures x, y coordinates normalized to 0.0-1.0 range (relative to display)
- Captures pressure with 4096 levels (0-4095)
- Captures tilt_x and tilt_y in degrees
- Distinguishes stylus from touch via MotionEvent.getToolType() == TOOL_TYPE_STYLUS
- Captures hover/proximity events (pen near surface but not touching)
- Event rate matches digitizer native rate (~200Hz)

#### Scenario: Pen down
**Given** the stylus is hovering above the screen
**When** the pen tip touches the surface
**Then** a pen-down event is captured with x, y (normalized), pressure > 0, and tilt values

#### Scenario: Pen move with pressure
**Given** the pen is in contact with the screen
**When** the user draws a stroke with varying pressure
**Then** a stream of move events is captured at ~200Hz, each with updated x, y, pressure (0-4095), and tilt values

#### Scenario: Pen lift
**Given** the pen is in contact with the screen
**When** the pen is lifted from the surface
**Then** a pen-up event is captured with pressure = 0, and subsequent events transition to hover mode

#### Scenario: Tilt detection
**Given** the pen is in contact with the screen
**When** the user tilts the pen at a 45-degree angle
**Then** tilt_x and tilt_y values reflect the physical tilt angle accurately

#### Scenario: Hover (proximity)
**Given** the pen is within EMR detection range (~10mm) but not touching
**When** the pen moves above the surface
**Then** hover events are captured with x, y position, pressure = 0, and a hover flag set

**Cross-references:** `transport`

---

### Requirement: Touch Capture

The system MUST capture capacitive touch events from the Boox Tab Ultra C's touchscreen for mouse-like interaction. Support common gestures: single tap, drag, two-finger scroll, and pinch-to-zoom.

**Acceptance Criteria:**
- Single tap maps to mouse click
- Drag maps to mouse drag (button held)
- Two-finger vertical scroll maps to scroll wheel events
- Pinch gesture maps to zoom (Cmd+scroll or trackpad pinch)
- Touch events are distinguished from stylus events

#### Scenario: Single tap
**Given** the user touches the screen with one finger briefly
**When** the touch-down and touch-up occur within 200ms and 10px movement threshold
**Then** a tap event is captured with x, y coordinates (normalized 0-1)

#### Scenario: Drag gesture
**Given** the user touches the screen and moves their finger
**When** the finger moves beyond the 10px threshold while held down
**Then** a drag event stream is captured with start position, current position, and drag-active flag

#### Scenario: Two-finger scroll
**Given** the user places two fingers on the screen
**When** both fingers move vertically in the same direction
**Then** a scroll event is captured with scroll delta (dx, dy) values

#### Scenario: Multi-touch pinch
**Given** the user places two fingers on the screen
**When** the fingers move apart or together
**Then** a pinch event is captured with scale factor (>1.0 for zoom in, <1.0 for zoom out) and center point

**Cross-references:** `transport`

---

### Requirement: Event Serialization

The system SHALL serialize captured input events into compact binary packets for efficient transport over the ADB tunnel. Each event packet is exactly 20 bytes with a fixed layout for zero-copy parsing on the Mac side.

Packet format:
| Offset | Size | Field | Type |
|--------|------|-------|------|
| 0 | 1 | type | uint8: 0x01=stylus, 0x02=touch, 0x03=scroll, 0x04=pinch |
| 1 | 4 | x | float32 (normalized 0.0-1.0) |
| 5 | 4 | y | float32 (normalized 0.0-1.0) |
| 9 | 2 | pressure | uint16 (0-4095) |
| 11 | 2 | tilt_x | int16 (degrees) |
| 13 | 2 | tilt_y | int16 (degrees) |
| 15 | 1 | flags | uint8: bit 0=down, bit 1=hover, bit 2=eraser, bits 3-7=reserved |
| 16 | 4 | timestamp | uint32 (milliseconds since session start) |

**Acceptance Criteria:**
- Each packet is exactly 20 bytes
- All multi-byte fields use big-endian byte order
- Serialization and deserialization are inverse operations (roundtrip lossless)
- Handles boundary values (0.0, 1.0, max pressure, extreme tilt)

#### Scenario: Roundtrip serialization
**Given** a stylus event with x=0.5, y=0.75, pressure=2048, tilt_x=15, tilt_y=-10, flags=0x01, timestamp=12345
**When** the event is serialized to 20 bytes and then deserialized
**Then** all fields match the original values exactly

#### Scenario: Boundary values
**Given** events with minimum and maximum values (x=0.0, y=1.0, pressure=0, pressure=4095, tilt=-90, tilt=90)
**When** serialized and deserialized
**Then** all boundary values are preserved without overflow or underflow

#### Scenario: Rapid event stream
**Given** a burst of 200 stylus events in 1 second (200Hz digitizer rate)
**When** all events are serialized
**Then** total serialized size is 4000 bytes (200 * 20), and each event retains correct ordering by timestamp

**Cross-references:** `transport`

---

### Requirement: Mac Input Injection

The system MUST inject received stylus and touch events as native macOS input events using CGEvent and IOKit APIs. Stylus events are injected as tablet events (with pressure and tilt), not just mouse events, enabling pressure-sensitive drawing in apps like Photoshop, Procreate, and Krita.

**Acceptance Criteria:**
- Stylus movement maps to cursor position on the virtual display
- Pressure maps to CGEvent tablet pressure (0.0-1.0)
- Tilt maps to CGEvent tablet tilt (x, y)
- Pen down/up maps to mouse button down/up events
- Touch tap maps to mouse click
- Scroll events map to scroll wheel events
- Requires macOS Accessibility permission (prompts user if not granted)

#### Scenario: Stylus movement maps to cursor
**Given** a stylus move event with x=0.5, y=0.25
**When** the event is injected
**Then** the macOS cursor moves to the corresponding position on the virtual display (center-x, quarter-y)

#### Scenario: Pressure maps to tablet pressure
**Given** a stylus event with pressure=2048 (50% of 4096 range)
**When** the event is injected as a CGEvent tablet event
**Then** the tablet pressure property is set to 0.5, and pressure-aware apps respond accordingly

#### Scenario: Tilt maps correctly
**Given** a stylus event with tilt_x=30, tilt_y=-15
**When** the event is injected as a CGEvent tablet event
**Then** the tablet tilt properties reflect the pen angle, enabling tilt-aware brush behavior in drawing apps

#### Scenario: Pen up/down events
**Given** a pen-down event followed by a pen-up event
**When** the events are injected
**Then** macOS receives a mouse-button-down followed by a mouse-button-up, equivalent to a click, with tablet metadata attached

**Cross-references:** `app-shell`
