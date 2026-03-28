## ADDED Requirements

### Requirement: Greyscale Conversion

The pipeline MUST convert BGRA pixel buffers to 8-bit greyscale using BT.709 luminance coefficients. The formula is: Y = R * 0.2126 + G * 0.7152 + B * 0.0722. This is the first stage of the image pipeline and must be fast enough to process at frame rate.

**Acceptance Criteria:**
- Input: BGRA pixel buffer (4 bytes per pixel)
- Output: 8-bit greyscale buffer (1 byte per pixel)
- Uses BT.709 coefficients exactly (R*0.2126 + G*0.7152 + B*0.0722)
- Processes 1240x930 frame in <1ms on Apple Silicon
- Uses SIMD/Accelerate.framework for vectorized computation

#### Scenario: All-white input
**Given** a BGRA buffer where every pixel is (255, 255, 255, 255)
**When** greyscale conversion is applied
**Then** every output pixel is 255

#### Scenario: All-black input
**Given** a BGRA buffer where every pixel is (0, 0, 0, 255)
**When** greyscale conversion is applied
**Then** every output pixel is 0

#### Scenario: Pure red/green/blue channels
**Given** a BGRA buffer with pure red (255,0,0), pure green (0,255,0), and pure blue (0,0,255) regions
**When** greyscale conversion is applied
**Then** red region yields ~54 (0.2126*255), green region yields ~182 (0.7152*255), blue region yields ~18 (0.0722*255)

#### Scenario: Natural photo content within latency budget
**Given** a 1240x930 BGRA buffer containing a natural photograph
**When** greyscale conversion is applied
**Then** output is perceptually correct greyscale and processing completes in <1ms

**Cross-references:** `screen-capture`, `delta-encoding`

---

### Requirement: Contrast LUT

The pipeline SHALL apply configurable gamma correction and contrast stretching via a precomputed 256-entry lookup table. The LUT is recomputed only when gamma changes, not per-frame. Default gamma is 1.2 to compensate for e-ink's lower contrast ratio compared to LCD.

**Acceptance Criteria:**
- LUT maps each input grey level (0-255) to an output grey level (0-255)
- Default gamma is 1.2
- Gamma is configurable from 0.5 to 3.0
- LUT is precomputed and cached -- only recomputed on gamma change
- Gamma 1.0 produces identity mapping (output = input)

#### Scenario: Default gamma (1.2)
**Given** gamma is set to 1.2 (default)
**When** a greyscale frame is processed through the LUT
**Then** midtones are brightened (e.g., input 128 maps to ~141), shadows are lifted, and overall contrast is optimized for e-ink viewing

#### Scenario: Custom gamma range 0.5-3.0
**Given** gamma is set to 2.0
**When** a greyscale frame is processed through the LUT
**Then** contrast is significantly increased with deeper shadows and brighter highlights compared to gamma 1.2

#### Scenario: Edge case gamma=1.0 (identity)
**Given** gamma is set to 1.0
**When** a greyscale frame is processed through the LUT
**Then** every pixel value is unchanged (LUT[i] == i for all i in 0-255)

**Cross-references:** `app-shell`

---

### Requirement: Sharpening

The pipeline SHALL apply Laplacian convolution unsharp mask to enhance text edges and fine detail for e-ink display. E-ink's slower pixel response benefits from pre-sharpened content. Intensity is configurable to balance between soft images and ringing artifacts.

**Acceptance Criteria:**
- Uses Laplacian kernel for edge detection
- Sharpening intensity configurable from 0.0 (disabled) to 3.0 (maximum)
- Default intensity is 1.5
- No out-of-bounds pixel values (clamp to 0-255)
- Single-pixel features are not destroyed

#### Scenario: Sharpening disabled (intensity 0.0)
**Given** sharpening intensity is set to 0.0
**When** a greyscale frame is processed
**Then** the output frame is identical to the input frame (no modification)

#### Scenario: Default sharpening on text content
**Given** sharpening intensity is set to 1.5 (default)
**When** a greyscale frame containing text is processed
**Then** text edges show increased contrast (darker text, lighter background at boundaries) and text appears crisper

#### Scenario: Maximum sharpening (intensity 3.0)
**Given** sharpening intensity is set to 3.0
**When** a greyscale frame is processed
**Then** edges are heavily emphasized, visible halo artifacts may appear around high-contrast boundaries, and all pixel values remain clamped to 0-255

#### Scenario: Single-pixel features preserved
**Given** a greyscale frame containing single-pixel-wide lines
**When** sharpening is applied at default intensity
**Then** single-pixel features remain visible and are not erased by the convolution

**Cross-references:** `app-shell`

---

### Requirement: Atkinson Dithering

The pipeline MUST quantize 256-level greyscale to 16-level greyscale using Atkinson error diffusion for B&W display mode. Atkinson dithering diffuses only 3/4 of the quantization error (unlike Floyd-Steinberg which diffuses all error), producing higher contrast and more suitable output for e-ink panels.

**Acceptance Criteria:**
- Input: 8-bit greyscale (256 levels)
- Output: 4-bit greyscale (16 levels, stored as 8-bit with values 0, 17, 34, ..., 255)
- Uses Atkinson error diffusion pattern (6 neighbors, 1/8 each, total 6/8 = 3/4)
- Processes left-to-right, top-to-bottom
- Higher contrast than Floyd-Steinberg on same input

#### Scenario: Smooth gradient
**Given** a greyscale buffer containing a horizontal gradient from 0 to 255
**When** Atkinson dithering is applied
**Then** output shows a smooth perceptual gradient using dither patterns, transitioning through all 16 output levels

#### Scenario: Text content
**Given** a greyscale buffer containing black text on white background
**When** Atkinson dithering is applied
**Then** text remains sharp and legible with minimal dithering artifacts in the solid regions

#### Scenario: Solid color (no dithering needed)
**Given** a greyscale buffer that is uniformly grey level 128
**When** Atkinson dithering is applied
**Then** output is uniform at the nearest 16-level quantization step (level 119 or 136) with minimal scattered error pixels

#### Scenario: Checkerboard pattern
**Given** a greyscale buffer with alternating 0 and 255 pixels in a checkerboard
**When** Atkinson dithering is applied
**Then** the checkerboard structure is preserved in the output without introducing large-scale artifacts

**Cross-references:** `eink-renderer`

---

### Requirement: Color Quantization

The pipeline MUST quantize full-color BGRA to 4096 colors using an octree color quantization algorithm for Kaleido 3 color e-ink display mode. The Boox Tab Ultra C's Kaleido 3 panel natively supports 4096 colors, so quantizing to this palette avoids banding from the panel's own dithering.

**Acceptance Criteria:**
- Input: BGRA pixel buffer (16.7M colors)
- Output: BGRA pixel buffer quantized to 4096 representative colors
- Uses octree algorithm for adaptive palette generation
- Palette is computed per-frame or cached when content is similar
- Near-boundary colors map consistently (no flickering between frames)

#### Scenario: Photo content
**Given** a BGRA buffer containing a natural photograph with millions of colors
**When** octree color quantization is applied
**Then** output contains at most 4096 unique colors and perceptual quality is acceptable (no obvious banding in smooth gradients)

#### Scenario: Solid colors
**Given** a BGRA buffer containing large regions of exactly 10 distinct colors
**When** octree color quantization is applied
**Then** each color maps to itself or the nearest 4096-palette entry, and output contains exactly those 10 colors (or fewer)

#### Scenario: Text on colored background
**Given** a BGRA buffer containing black text on a pastel blue background
**When** octree color quantization is applied
**Then** text remains sharp and legible, background color is consistent, and no dithering artifacts appear in solid regions

#### Scenario: Near-boundary colors
**Given** two BGRA buffers where some pixels differ by only 1 LSB in one channel
**When** octree color quantization is applied to both
**Then** those pixels map to the same output color in both frames (no flicker)

**Cross-references:** `eink-renderer`

---

### Requirement: Mode Toggle

The system MUST switch between B&W and Color render modes at runtime without disconnecting the transport layer or restarting the capture pipeline. Mode toggle changes which image processing stages are active: B&W mode uses greyscale + dithering, Color mode uses color quantization.

**Acceptance Criteria:**
- Mode switch completes within one frame interval
- No frames are lost during the switch
- Transport connection remains active
- A mode flag is set in the protocol header to inform the renderer

#### Scenario: B&W to Color mode switch
**Given** mirroring is active in B&W mode (greyscale + Atkinson dithering)
**When** the user switches to Color mode
**Then** the pipeline switches to color quantization, the next frame is processed in color mode, and the transport header mode flag is updated

#### Scenario: Color to B&W mode switch
**Given** mirroring is active in Color mode (octree quantization)
**When** the user switches to B&W mode
**Then** the pipeline switches to greyscale + contrast LUT + sharpening + Atkinson dithering, and the next frame uses B&W processing

#### Scenario: Mode switch during active frame delivery
**Given** a frame is currently being processed in B&W mode
**When** the user requests a Color mode switch
**Then** the current frame completes in B&W mode, and the very next frame is processed in Color mode with no dropped frames

**Cross-references:** `transport`, `eink-renderer`, `app-shell`
