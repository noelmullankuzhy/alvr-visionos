# Crop FOV to outline

**What it does.** With the Diagnostics setting *Crop FOV to outline* on, the client reports to the server, for each eye,
the Boundary dots model lens's inset rectangle (the rectangle the lens curve is inscribed in, which is the lens's
bounding box) instead of the whole Apple frustum. The server renders that smaller box at the
same render size, so each pixel covers less angle. At the configured render resolution, the centre density rises by
the ratio of the tangent spans. The client draws the frame on the box it sent, and the rest of the frustum stays
black (the eye cannot see it).

## Mechanism

| Step | Code | What happens |
|---|---|---|
| 1 Settings | `GlobalSettings.cropFovToOutline` (off), `cropMarginDeg` (2.0); Entry → Diagnostics | Read when the view config is sent, i.e. at stream start (and when the IPD changes) |
| 2 Rectangle | `BoundaryDotsLensModel.insetRect(eye, frustum:, insetDeg:)`: each edge angle of the device frustum moved in by the inset, at least 1° left, R mirrored | The inset is the Boundary dots lens slider's last value per eye in this app session (`CropFov.recordInset`), 15° until the slider is moved |
| 3 Box | `BoundaryDotsLensRect.box(eye)` (head-frame sides), then `CropFov.tangents` | Each side is widened by the margin in degrees (`tan(atan t + m)`), then clamped to the device frustum side |
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

## Numbers (model lens, inset 15°, margin 2°)

| | L left (temporal) | right (nasal) | down | up | span h × v |
|---|---|---|---|---|---|
| Device frustum | 1.7321 (60.0°) | 1.0 (45°) | 1.1918 (50.0°) | 1.0 (45°) | 2.7321 × 2.1918 |
| Inset rectangle, 15° | 1.0000 (45.0°) | 0.5774 (30°) | 0.7002 (35.0°) | 0.5774 (30°) | 1.5774 × 1.2776 (×1.73 / ×1.72) |
| **Sent, + 2°** | 1.0724 (47.0°) | 0.6249 (32°) | 0.7536 (37.0°) | 0.6249 (32°) | 1.6973 × 1.3785 (**×1.61 / ×1.59**) |

R mirrors L (left and right swap). The axis centre shift at c 0.5/0.45 is **0.527 / −0.170**.

| Points row (`points-chart-avp.tsv`) | Render | Foveation | Centre px/deg | Full frustum at the same render |
|---|---|---|---|---|
| `a100-crop-C` | 4176×3334 (budget C) | 0.5,0.45,3,3,0.527,−0.17 | **42.2** (v binds; h 42.9) | 26.5 (`a100-axis-C`) |
| `a100-crop-A` | 3648×2912 (budget A) | same | **36.9** | 23.2 (`a100-axis-A`) |

Before the model lens (22 Oct 2026) the crop was the W34 measured outline's bbox (seal-on rays, offset 0) + 2°:
L 0.9494/0.8243/0.6873/0.6646, shift 0.141/−0.031, `a100-crop-C` 41.1 and `a100-crop-A` 35.9 px/deg. The inset-15
rectangle is wider temporally and narrower nasally than that bbox, so the axis sits further off the frame centre
(shift x 0.527) and the centre density rises by about 1 px/deg.

Both rows carry `eye_tangents=` with the sent box, so the simulator matrix runs the crop through
`-ALVRDebugEyeTangents`. The tangents are generated by `python3 tools/diag/avp-sharpness.py points` from
`tools/fov-matrix/avp-field.json` `crop` (inset_deg, margin_deg) with `tools/diag/lens_model.py`.
`tools/diag/fixtures/crop-fov.json` pins the Swift and Python formulas to each other, and
`tools/diag/fixtures/lens-model.json` pins the two lens models.

## Settings

- *Crop FOV to outline*: off by default. It takes effect at the next view-config send (stream start).
- *Crop margin*: 0–10° in 0.5° steps, default 2°. This is the slack for fit and eye position. At 0 the box is exactly
  the inset rectangle.
- Lens inset: move the Boundary dots lens slider (lens style, 0–30° in 0.5° steps, default 15°) for L and R before the
  stream. The app does not keep it between launches.
- Server dashboard: set Foveated encoding → center shift x/y to the logged `axis_center_shift`. Keep the centre size
  the client logged it for. Render resolution stays as configured, and the crop spends it on the smaller box.

## Verify on the device

1. Turn Diagnostics and *Crop FOV to outline* on, then start a stream. Expect one line per eye:
   `DIAG fov_sent eye=L up=32.x down=-37.x left=-47.x right=32.x units=deg source=crop margin_deg=2 offset_deg=15
   axis_center_shift=0.52x,-0.17x session_center_shift=<dashboard values>`. `offset_deg` keeps its name (the
   fov_sent fields are unchanged) and carries the model lens inset. The degrees are about 1% wider than the
   table above, because of the canting factor. `source=frustum` means the setting is off, and `source=debug` means a
   launch argument overrides it.
2. Look at the image. The game picture fills only the sent rectangle and the outer frustum is black. The lens edge
   should sit inside the picture on every side. Black inside the lens ring means the margin is too small or the inset
   too large.
3. Boundary dots readout (no stream, lens style). The `bbox` line gives the inset rectangle without the margin, and
   `px/deg axis: frustum → bbox` gives the predicted gain at the shown render size.
4. Sharpness. W33's auto chart measures the display path with no stream (its finest correct is 17 cpd), so it does not
   change with the crop. It gives the ceiling the stream can reach. To see the stream's gain, run the same chart
   content through the stream (W35b golden frame, or an in-game target) with the setting off and then on. With the
   band on the axis, expect the finest resolved cpd to rise by about ×1.5. This is unmeasured.
