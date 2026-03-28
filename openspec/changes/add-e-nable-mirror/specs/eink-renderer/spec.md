## ADDED Requirements

### Requirement: Delta Patch Application

The renderer MUST receive compressed delta patches over the transport layer and apply them to the screen buffer to reconstruct the current frame. The renderer maintains a reference frame and applies XOR deltas to produce the display frame. Corrupted data must be detected and handled gracefully.

**Acceptance Criteria:**
- Decompresses LZ4 delta payload
- XOR-applies delta to the stored reference frame to produce display frame
- Updates reference frame after successful apply
- Handles keyframes by replacing the reference frame entirely
- Detects corruption (LZ4 decode failure, size mismatch) and requests a new keyframe

#### Scenario: Partial update (delta patch)
**Given** the renderer has a valid reference frame
**When** a compressed delta patch arrives
**Then** the delta is decompressed, XOR-applied to the reference frame, and the updated frame is displayed

#### Scenario: Full keyframe
**Given** a keyframe arrives (keyframe flag set in header)
**When** the renderer processes it
**Then** the reference frame is replaced entirely with the decompressed keyframe content, and the full frame is displayed

#### Scenario: Empty delta (skip rendering)
**Given** the renderer receives a delta that decompresses to all zeros
**When** the delta is applied
**Then** the reference frame is unchanged, no display update is triggered, and CPU is conserved

#### Scenario: Corrupted data
**Given** the renderer receives a packet with invalid LZ4 data or mismatched payload size
**When** decompression fails
**Then** the corrupted packet is discarded, the reference frame is preserved, and a keyframe request is sent to the host

**Cross-references:** `delta-encoding`, `transport`

---

### Requirement: BSR Mode Selection

The renderer SHALL select the optimal Boox Super Refresh (BSR) mode based on the size of the dirty region relative to the total screen area. Smaller changes use faster, lower-quality refresh modes; larger changes use slower, higher-quality modes.

| Dirty % | Mode | Description |
|----------|------|-------------|
| <10% | DW (Direct Write) | Fastest, minimal flicker, slight ghosting |
| 10-60% | GU (Grey Update) | Balanced speed and quality |
| >60% | GC (Grey Clear) | Full refresh, no ghosting, slowest |

**Acceptance Criteria:**
- Calculates dirty percentage from dirty region rectangles
- Selects DW for <10%, GU for 10-60%, GC for >60%
- Calls EpdController.invalidate(view, mode) with the selected mode
- Thresholds are configurable

#### Scenario: Cursor blink (DW mode)
**Given** a delta arrives with a dirty region covering <1% of the screen (cursor area)
**When** BSR mode is selected
**Then** DW mode is used for fastest refresh with minimal flicker

#### Scenario: Text editing (DW mode)
**Given** a delta arrives with dirty regions covering ~5% of the screen (line of text)
**When** BSR mode is selected
**Then** DW mode is used for responsive text input

#### Scenario: Window switch (GU mode)
**Given** a delta arrives with dirty regions covering ~40% of the screen
**When** BSR mode is selected
**Then** GU mode is used for balanced speed and quality

#### Scenario: Full scroll (GC mode)
**Given** a delta arrives with dirty regions covering >60% of the screen
**When** BSR mode is selected
**Then** GC mode is used for a clean full refresh with no ghosting

**Cross-references:** `delta-encoding`

---

### Requirement: Partial Refresh

The renderer MUST apply partial refresh to only the dirty regions identified by delta encoding, rather than refreshing the entire screen. This dramatically reduces refresh time and flicker for small changes like cursor movement or text input.

**Acceptance Criteria:**
- Uses EpdController with region coordinates (x, y, width, height)
- Only dirty regions are refreshed; unchanged areas are untouched
- Multiple dirty regions are refreshed in sequence or batched
- Overlapping regions are merged before refresh

#### Scenario: Single small region
**Given** a delta identifies one dirty region at (100, 200, 50, 20)
**When** partial refresh is triggered
**Then** only the rectangle (100, 200, 50, 20) is refreshed on the e-ink panel, and surrounding pixels are untouched

#### Scenario: Multiple regions
**Given** a delta identifies three dirty regions in different screen areas
**When** partial refresh is triggered
**Then** each region is refreshed independently using the appropriate BSR mode, minimizing total refresh area

#### Scenario: Overlapping regions
**Given** a delta identifies two dirty regions that overlap
**When** partial refresh is triggered
**Then** the overlapping regions are merged into a single bounding rectangle before refresh to avoid double-refreshing pixels

**Cross-references:** `delta-encoding`

---

### Requirement: Ghost Mitigation

The renderer SHALL schedule periodic full GC (Grey Clear) refresh to clear accumulated ghosting artifacts. E-ink displays accumulate ghosting over many partial refreshes, and periodic full clears maintain display quality.

**Acceptance Criteria:**
- Automatic full GC refresh every N partial refreshes (configurable, default 30)
- Manual full GC refresh available on user request
- Full GC refresh on mode switch (B&W to Color or vice versa)
- Ghost clear counter resets after each full refresh

#### Scenario: Automatic ghost clear after N frames
**Given** 30 partial refreshes have been applied since the last full GC refresh
**When** the next frame arrives
**Then** a full-screen GC refresh is triggered before applying the new frame, and the counter resets to 0

#### Scenario: User-requested ghost clear
**Given** the user notices ghosting and triggers a manual clear (via menu or keyboard shortcut)
**When** the ghost clear command is received
**Then** an immediate full-screen GC refresh is performed and the automatic counter resets

#### Scenario: Ghost clear on mode switch
**Given** the display mode changes from B&W to Color (or Color to B&W)
**When** the mode switch is processed
**Then** a full-screen GC refresh is performed to clear any B&W ghosting before rendering in the new mode

**Cross-references:** `image-pipeline`, `app-shell`

---

### Requirement: Dual Render Path

The renderer MUST support two rendering paths optimized for the Boox Tab Ultra C's dual-layer display: B&W mode renders at 300ppi using the E Ink Carta layer, and Color mode renders at 150ppi using the Kaleido 3 color filter array layer.

**Acceptance Criteria:**
- B&W mode: renders at native 300ppi (2480x1860 for full resolution)
- Color mode: renders at native 150ppi (1240x930 for full resolution)
- Mode is determined by the flags byte in the transport protocol header
- Mode switch does not require reconnection
- Each mode uses the appropriate image pipeline output

#### Scenario: B&W mode rendering
**Given** a frame arrives with the color mode flag cleared (flags & 0x02 == 0)
**When** the renderer processes the frame
**Then** the frame is rendered using the E Ink Carta layer at 300ppi, using 16-level greyscale from Atkinson dithering

#### Scenario: Color mode rendering
**Given** a frame arrives with the color mode flag set (flags & 0x02 == 1)
**When** the renderer processes the frame
**Then** the frame is rendered using the Kaleido 3 layer at 150ppi, using the 4096-color quantized output

#### Scenario: Mode switch during rendering
**Given** the renderer is displaying B&W frames
**When** a frame arrives with the color mode flag newly set
**Then** the renderer switches to the color render path, triggers a full GC refresh for clean transition, and subsequent frames use color rendering

**Cross-references:** `image-pipeline`, `transport`
