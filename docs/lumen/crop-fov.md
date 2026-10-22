# Crop FOV to outline

**What it does.** With the Diagnostics setting *Crop FOV to outline* on (the default since the W37/W39 follow-ups), the client reports to the server, for each eye,
the Boundary dots model lens's inset rectangle (the rectangle the lens curve is inscribed in, which is the lens's
bounding box) instead of the whole Apple frustum. The server renders that smaller box at the
same render size, so each pixel covers less angle. At the configured render resolution, the centre density rises by
the ratio of the tangent spans. The client draws the frame on the box it sent, and the rest of the frustum stays
black (the eye cannot see it).

## Mechanism

| Step | Code | What happens |
|---|---|---|
| 1 Settings | `GlobalSettings.cropFovToOutline` (on, `CropFov.defaultEnabled`), `cropMarginDeg` (2.5, `CropFov.defaultMarginDeg`); Entry → Diagnostics | Read when the view config is sent, i.e. at stream start (and when the IPD changes) |
| 2 Rectangle | `BoundaryDotsLensModel.insetRect(eye, frustum:, insetDeg:)`: each edge angle of the device frustum moved in by the inset, at least 1° left, R mirrored | The inset is one value for both eyes: the Boundary dots lens slider's last value on either eye in this app session (`CropFov.recordInset`), 15° until the slider is moved |
| 3 Box | `BoundaryDotsLensRect.box(eye)` (head-frame sides), then `CropFov.tangents` | Each side is widened by the margin in degrees (`tan(atan t + m)`), then clamped to the device frustum side, to 0 or more, and to an edge angle below 89° (`CropFov.maxEdgeDeg`) |
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

## Numbers (model lens, inset 15°, margin 2.5°)

| | L left (temporal) | right (nasal) | down | up | span h × v |
|---|---|---|---|---|---|
| Device frustum | 1.7321 (60.0°) | 1.0 (45°) | 1.1918 (50.0°) | 1.0 (45°) | 2.7321 × 2.1918 |
| Inset rectangle, 15° | 1.0000 (45.0°) | 0.5774 (30°) | 0.7002 (35.0°) | 0.5774 (30°) | 1.5774 × 1.2776 (×1.73 / ×1.72) |
| **Sent, + 2.5°** | 1.0913 (47.5°) | 0.6371 (32.5°) | 0.7674 (37.5°) | 0.6371 (32.5°) | 1.7284 × 1.4044 (**×1.58 / ×1.56**) |

R mirrors L (left and right swap). The axis centre shift at c 0.5/0.45 is **0.526 / −0.169**. (The default margin was 2° until 22 Oct 2026: sent 1.0724/0.6249/0.7536/0.6249, shift 0.527/−0.170, `a100-crop-C` 4176×3334 at 42.2 px/deg and `a100-crop-A` 36.9.)

| Points row (`points-chart-avp.tsv`) | Render | Foveation | Centre px/deg | Full frustum at the same render |
|---|---|---|---|---|
| `a100-crop-C` | 3968×3232 (the 1:1 render, below; `render_scale` 1.0877) | 0.5,0.45,3,3,0.526,−0.169 | **40.1** (h binds; v 40.2) | 25.3 (same render) |
| `a100-crop-A` | 3648×2912 (budget A) | same | **36.2** (v binds) | 23.2 (`a100-axis-A`) |

Before the model lens (22 Oct 2026) the crop was the W34 measured outline's bbox (seal-on rays, offset 0) + 2°:
L 0.9494/0.8243/0.6873/0.6646, shift 0.141/−0.031, `a100-crop-C` 41.1 and `a100-crop-A` 35.9 px/deg. The inset-15
rectangle is wider temporally and narrower nasally than that bbox, so the axis sits further off the frame centre
(shift x 0.527) and the centre density rises by about 1 px/deg.

`a100-crop-T` is the band placement proposed for this frame, same frame and render as `a100-crop-C` (3968×3232, inset 15 + 2.5° margin). The full-detail band is flush with the nasal edge and reaches 30° temporal, 25° up and 30° down: centre size 0.7026 × 0.7431 (band / frame per axis) and shift 1.0 / −0.053 from the formula above, centre density 40.1 px/deg like `a100-crop-C`. At 3968×3232 it codes 3200×2688, over budget C (2784×2240); the largest render that fits budget C is 3376×2694. Parameters: `avp-field.json` `crop.band_T`.

All three rows carry `eye_tangents=` with the sent box, so the simulator matrix runs the crop through
`-ALVRDebugEyeTangents`. The tangents are generated by `python3 tools/diag/avp-sharpness.py points` from
`tools/fov-matrix/avp-field.json` `crop` (inset_deg, margin_deg) with `tools/diag/lens_model.py`.
`tools/diag/fixtures/crop-fov.json` pins the Swift and Python formulas to each other, and
`tools/diag/fixtures/lens-model.json` pins the two lens models.

## 1:1 render request

With *Crop FOV to outline* on, the client asks the server for the render size at which one render pixel is one pixel of
the display's logical grid on the sent frame. The grid is the compositor layer's rate-map screen size (6261×5023 at
render quality 1.0, `ResolutionChart`), so the density is that size over the device frustum's tangent width and height:
6261 / 2.7321 = 2291.64 and 5023 / 2.1918 = 2291.72 px per tangent unit (`CropFov.gridDensity`). The request is the
density times the sent frame's tangent spans, each side rounded up to a multiple of 32 (`CropFov.oneToOne`), the larger
of the two eyes. For L at inset 15 + 2.5°: 2291.64 × 1.7284 = 3960.9 → **3968** and 2291.72 × 1.4044 = 3218.6 →
**3232**. With crop off the request is the unchanged default (`renderWidth × 2` by `renderHeight × 2`, 3776×3648).

It is sent as `default_view_width` / `default_view_height` in `AlvrClientCapabilities` at `alvr_initialize`
(`EventHandler.initializeAlvr`), the only point at which the client reports a view size; the server reads it when the
client connects. The layer does not exist yet at that point, so the density is the last measured one
(`CropFov.recordGrid`, called from the render loop) and the reference device's (above) until then; the inset is the
slider's last value (15° until moved) and the margin is the setting. Consequences:

- The resolution is fixed per stream: the server builds its render target at connect. Changing the margin, the inset or
  the setting afterwards changes the frame sent but not the request; `fov_sent` shows `render_1to1` (now) next to
  `recommended` (sent at connect), and a mismatch means the next stream would ask for something else.
- The server only honours the request at its default scaling: its video resolution setting must be Scale 1.0 (the
  `Scale` variant of `video.transcoding_view_resolution` and `video.emulated_headset_view_resolution`, value 1.0, the
  ALVR default; `tools/fov-matrix` sets them to the `Absolute` variant, which overrides the request).
- `tools/fov-matrix` can only set both sides of an `Absolute` size through one `render_scale` × 3648×2912, so the
  `a100-crop-C` / `-T` rows carry `render_scale` 1.0877 (3968 / 3648 = 1.087719, exact), which gives 3968×3167 there, not
  3968×3232. Their predicted px/deg are for the true 1:1 size.

## Reprojection and the margin

The server's frame is warped to the current head pose, and with a smaller sent FOV that is the same code path as
`fov_scale` < 1: the smaller tangents become the same `sentViewTangents` (`Renderer.swift` ~:1005) and the quad sits at
the frame's pose (`modelViewMatrixFrame`, ~:681). Between the pose the frame was rendered for and the pose it is shown
at, the head moves, and the quad's edge moves with it. The 2.5° margin is what covers that head motion: a fast turn
(100°/s over 30–50 ms of latency is 3–5°) can still show a black edge inside the lens, so raise the margin if you see
one.

## Settings

- *Crop FOV to outline*: **on by default**. This changes the tangents sent to the server by default: a fresh install
  (or a settings file with no saved value) now streams the cropped box, not the device frustum, so the server's
  foveation centre shift must match `axis_center_shift` (below) or the 1:1 band sits off the axis. A saved `false`
  stays off, and the user can turn it off, which sends the device frustum as before. Debug tangents still win over the
  crop (debug > crop > frustum). It takes effect at the next view-config send (stream start). It does nothing on the
  RealityKit renderer.
- *Crop margin*: 0–10° in 0.5° steps, default 2.5° (a little extra each way, so the box is rounder than the inset rectangle). This is the slack for fit and eye position. At 0 the box is exactly
  the inset rectangle.
- Lens inset: move the Boundary dots lens slider (lens style, 0–30° in 0.5° steps, default 15°) on either eye before the
  stream; one value drives both eyes. The app does not keep it between launches.
- Server dashboard: set Foveated encoding → center shift x/y to the logged `axis_center_shift`. Keep the centre size
  the client logged it for. With crop on, the client also asks for the 1:1 render size (next section), which the server honours only at Scale 1.0.

## Verify on the device

1. Turn Diagnostics and *Crop FOV to outline* on, then start a stream. Expect one line per eye:
   `DIAG fov_sent eye=L up=32.x down=-37.x left=-47.x right=32.x units=deg source=crop margin_deg=2.5 inset_deg=15 offset_deg=0
   axis_center_shift=0.52x,-0.16x session_center_shift=<dashboard values> render_1to1=3968x3232 recommended=3968x3232`. `recommended` is the size sent at connect; `render_1to1` is what the frame sent now needs, so a mismatch means the inset, margin or setting changed after connect (see "1:1 render request"). `inset_deg` is the lens inset in force
   (0 when the tangents are not cropped); `offset_deg` is the measured-style offset again (0 for the lens). The degrees are about 1% wider than the
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
