# Crop FOV to outline

**What it does.** With the Diagnostics setting *Crop FOV to outline* on, the client reports to the server, for each eye,
the bounding box of the lens outline instead of the whole Apple frustum. The server renders that smaller box at the
same render size, so each pixel covers less angle. At the configured render resolution, the centre density rises by
the ratio of the tangent spans. The client draws the frame on the box it sent, and the rest of the frustum stays
black (the eye cannot see it).

## Mechanism

| Step | Code | What happens |
|---|---|---|
| 1 Settings | `GlobalSettings.cropFovToOutline` (off), `cropMarginDeg` (2.0); Entry → Diagnostics | Read when the view config is sent, i.e. at stream start (and when the IPD changes) |
| 2 Outline | `BoundaryDotsLensReference.outline(eye, offsetDeg:)` (W34): the 21 Oct seal-on rays, R mirrored | The offset is the Boundary dots lens slider's last value per eye in this app session (`CropFov.recordOffset`), 0 until the slider is moved |
| 3 Box | `ProjectionOverlay.bbox` (W36), then `CropFov.tangents` | Each side is widened by the margin in degrees (`tan(atan t + m)`), then clamped to the device frustum side |
| 4 Choice | `CropFov.choose`, called from `Renderer.swift` at the view-config send | `-ALVRDebugEyeTangents` wins, then the crop, then the device frustum |
| 5 Packing | `ViewLayout.fovAngles` (W32 up = `.w`), × `fovRenderScale`, then the canting circumscription (`_cantedViewToProportionalCircumscribedOrthogonal`, ×1.01–1.02 on device) | The `AlvrFov` sent to the server and `EventHandler.sentViewTangents` |
| 6 Display | `Renderer.swift` `updateGameStateForVideoFrame`: `Uniforms.tangents = sentTangents`, projection from `realTangents`; `Shaders.metal:205-216` builds the quad from `tangents` | The frame lands on the sent rectangle. Pass 0 clears to black (`beginRenderStreamingFrame`, `loadAction .clear`), so the outer frustum stays black |

**Display path: the sent tangents.** The Metal renderer already draws the video quad from the sent tangents
(`Renderer.swift` uniforms `tangents: sentTangents`; `Extensions/RealityKit.swift` packs them with
`ViewLayout.uniformTangents`). It uses the device tangents only for the projection. No display change was needed.
The **RealityKit renderer** (`realityKitRenderer` on) reports its own fixed tangents (`RealityKitClientSystem.swift`,
`DummyMetalRenderer.renderTangents`) and ignores the crop. Use the Metal renderer.

## Foveation centre

ALVR's 1:1 band spans eye UV [c0(1 + s), 1 − c0(1 − s)], with c0 = (1 − c)/2, so its centre is at 0.5 + s·c0
(`Shaders.metal:152-157`; `FFR.swift:88-89` only rounds s to 2r px). Eye UV x runs from the temporal edge (R is
mirrored, `Shaders.metal:136-140`) and y runs from the top row. In a frame spanning [−l, r] × [−d, u] in tangents, the
eye axis (tan 0) is at fraction temporal/(temporal + nasal) across and u/(u + d) down. So:

    center_shift_x = (temporal / (temporal + nasal) − 0.5) / ((1 − c_x) / 2)
    center_shift_y = (up / (up + down) − 0.5) / ((1 − c_y) / 2)          (negative moves the band up)

ALVR uses one shift for both eyes. Swift (`CropFov.centerShift`) and Python (`avp-sharpness.py crop_shift`) take the
mean of the two eyes, which is the same value for mirrored eyes. On the device frustum this formula gives the a100-axis
rows' 0.536/−0.159.

**Server: the shift comes from the session settings only.** `alvr/server_core/src/connection.rs:126-139` copies
`video.foveated_encoding.center_shift_x/y` (`session/src/settings.rs:558`) into the OpenVR config. From there it goes
to `Settings.cpp:55-56` and then `platform/win32/FFR.cpp:35-36` (Linux: `FrameRender.cpp:111-112`). The server never
derives the shift from the reported FOV. The client decodes with the same session values (`FFR.swift:74-75` via
`EventHandler.swift`). An asymmetric cropped FOV therefore needs no protocol or server change. Set the session's
`center_shift_x/y` to the value the client logs as `axis_center_shift`. With the session's own shift (e.g. the axis
rows' 0.536/−0.159), the band's centre sits 0.10 of the frame width temporal of the axis and 0.035 of the frame
height above it. The 1:1 band still covers the axis (x 0.384–0.884 around 0.535; y 0.231–0.681 around 0.492), but
off-centre.

## Numbers (seal-on reference, offset 0, margin 2°)

| | L left (temporal) | right (nasal) | down | up | span h × v |
|---|---|---|---|---|---|
| Device frustum | 1.7321 (60°) | 1.0 (45°) | 1.1918 (50°) | 1.0 (45°) | 2.7321 × 2.1918 |
| Lens bbox (W36) | 0.8851 (41.5°) | 0.7673 (37.5°) | 0.6371 (32.5°) | 0.6154 (31.6°) | 1.6524 × 1.2524 (×1.65 / ×1.75) |
| **Sent, + 2°** | 0.9494 (43.5°) | 0.8243 (39.5°) | 0.6873 (34.5°) | 0.6646 (33.6°) | 1.7737 × 1.3519 (**×1.54 / ×1.62**) |

R mirrors L (left and right swap). The axis centre shift at c 0.5/0.45 is **0.141 / −0.031**.

| Points row (`points-chart-avp.tsv`) | Render | Foveation | Centre px/deg | Full frustum at the same render |
|---|---|---|---|---|
| `a100-crop-C` | 4176×3334 (budget C) | 0.5,0.45,3,3,0.141,−0.031 | **41.1** (h binds; v 43.0) | 26.5 (`a100-axis-C`) |
| `a100-crop-A` | 3648×2912 (budget A) | same | **35.9** | 23.2 (`a100-axis-A`) |

Both rows carry `eye_tangents=` with the sent box, so the simulator matrix runs the crop through
`-ALVRDebugEyeTangents`. The tangents are generated by `python3 tools/diag/avp-sharpness.py points` from
`tools/fov-matrix/avp-field.json` `crop`. `tools/diag/fixtures/crop-fov.json` pins the Swift and Python formulas to
each other.

The brief's ×1.70/×1.81 does not come from this reference. GOAL 65r's "~1.70×" is the superellipse field fit's box
(3514 × 3093 of 6261 × 5023 logical px). The W34 polygon's own bbox gives ×1.65/×1.75, and with the 2° margin it gives
×1.54/×1.62. A seal-off measurement replaces the reference rays (`BoundaryDotsLensReference`, `avp-field.json crop`,
the fixture) and these numbers with it.

## Settings

- *Crop FOV to outline*: off by default. It takes effect at the next view-config send (stream start).
- *Crop margin*: 0–10° in 0.5° steps, default 2°. This is the slack for fit and eye position. At 0 the box is exactly
  the measured outline.
- Lens offset: move the Boundary dots lens slider (lens style) for L and R before the stream. The app does not keep it
  between launches.
- Server dashboard: set Foveated encoding → center shift x/y to the logged `axis_center_shift`. Keep the centre size
  the client logged it for. Render resolution stays as configured, and the crop spends it on the smaller box.

## Verify on the device

1. Turn Diagnostics and *Crop FOV to outline* on, then start a stream. Expect one line per eye:
   `DIAG fov_sent eye=L up=33.6x down=-34.5x left=-43.5x right=39.5x units=deg source=crop margin_deg=2 offset_deg=0
   axis_center_shift=0.14x,-0.03x session_center_shift=<dashboard values>`. The degrees are about 1% wider than the
   table above, because of the canting factor. `source=frustum` means the setting is off, and `source=debug` means a
   launch argument overrides it.
2. Look at the image. The game picture fills only the bbox rectangle and the outer frustum is black. The lens edge
   should sit inside the picture on every side. Black inside the lens ring means the margin or offset is too small.
3. W36 Boundary dots readout (no stream, lens style). The `bbox` line gives the box without the margin, and
   `px/deg axis: frustum → bbox` gives the predicted gain at the shown render size.
4. Sharpness. W33's auto chart measures the display path with no stream (its finest correct is 17 cpd), so it does not
   change with the crop. It gives the ceiling the stream can reach. To see the stream's gain, run the same chart
   content through the stream (W35b golden frame, or an in-game target) with the setting off and then on. With the
   band on the axis, expect the finest resolved cpd to rise by about ×1.5. This is unmeasured.
