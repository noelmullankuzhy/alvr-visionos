# Golden frame: a known server frame pair on the device

A golden set (`tools/golden/golden-frame.py`, README there) is a reference pair rendered on the Mac, sharper than the realtime
renderer, plus the server frame the client would receive for it (`L.server.png`, `R.server.png`: the foveated, side-by-side
coded frame). Golden frame mode shows that server pair through the client's own stream path, so reprojection, smoothness and
sharpness can be judged against a known truth: one frame per eye, held still, with the frustum rectangle, eye-axis cross and
lens outline drawn over it, and the W33 Auto capture to measure it.

## Make a set (Mac)

```sh
python3 tools/golden/golden-frame.py render --set chart80                    # L.png, R.png at 80 px/deg
python3 tools/golden/golden-frame.py encode --set chart80 --point a100-axis-C # L/R.server.png, meta.json
```

The set is `tools/golden/out/chart80/` (git-ignored). The client needs `meta.json`, `L.server.png` and `R.server.png`;
`L.png`/`R.png` (12523x10046 at 80 px/deg) are hashed if present but never loaded, so they can be left out of the push.

## Push it

```sh
python3 tools/golden/golden-frame.py push --set chart80 --device <id>
```

This only prints the command; run it yourself (the device id from `xcrun devicectl list devices`):

```sh
xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier <BUNDLE> \
  --source tools/golden/out/chart80 --destination Documents/diag/golden/chart80 --timeout 600
```

## Show it

Diag menu (Diagnostics on): set **Golden frame** to the set name (the picker lists the folders under
`Documents/diag/golden/`; Off disables the mode). The corner chart and resolution chart must be Off; they take precedence.
Then enter the immersive space, with or without a stream. The setting is read when the immersive space opens.

On entry the client:

1. parses `meta.json`. Any missing key, or a listed file whose sha256 differs, logs
   `DIAG golden step=error why=missing_key|unreadable|sha_mismatch|bad_image key=<path or file> set=` and the mode stays off;
2. decodes `L.server.png` and `R.server.png` with ImageIO (PNG code values as stored, no colour management) and converts them
   once, on the CPU, to one NV12 buffer, L | R side by side as the stream decodes it: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
   BT.709 full-range matrix, each 4:2:0 CbCr sample the box average of its 2x2 block. Chroma is therefore half resolution, as in
   the live stream (HEVC 4:2:0); luma is exact. Fine chroma edges blur by one server pixel; the grating chart is grey, so its luma
   carries everything measured;
3. feeds the pair to the stream's decoded-frame entry, `Renderer.beginRenderStreamingFrame(..., golden:)` (Renderer.swift:1919):
   the stream vertex shader, reprojection and fragment shader, with the set's colour state (BT.709 full range, sRGB transfer,
   encoding gamma 1, SDR) and pipelines built with the set's foveation (`meta.json` foveation). The live stream's pipelines,
   colour cache, telemetry and capture taps are untouched, so leaving the mode restores the live FFR and stream as they were.

The frame pose is the head pose at show time, so the frame is world-locked: turning the head moves the frame in view exactly
as a held stream frame reprojects.

## Controls

The status text sits under the eye-axis cross: the selected control and its value.

| input | action |
|---|---|
| pinch right / d-pad right or up | next control |
| pinch left / d-pad left or down | previous control |
| hold pinch right (>= 0.5 s) / A | apply |
| hold pinch left (>= 0.5 s) / B | back |

| control | status | apply | back |
|---|---|---|---|
| lock | `UorLd` / `HEAd` | toggle world / head lock (world re-pins at the current head) | re-pin at the current head |
| quality | `rq 0.75` | next of 0.5 / 0.75 / 1.0 | previous |
| overlays | `OL 111` | next of 111, 100, 010, 001, 000 (frustum, axis, lens) | previous |
| capture | `CAP` | start the Auto capture | - |
| exit | `End` | leave the mode (live stream or the no-stream pass) | - |

- Overlays: the frustum rectangle (`overlays.frustum_rect`, eye colour, follows the frame's pose), the eye-axis cross
  (yellow, `overlays.eye_axis`), the lens outline (green, `overlays.lens_outline`; drawn only if the set has one). There is no
  W34 lens reference or slider in this client, so none is offered.
- Quality changes are confirmed by the W33 settle rule (rate map screen size within 1 % of the expected size for 30
  frames; the read-back without a map; timeout after 600 frames) and logged as `DIAG golden step=settled`.
- There is no client sharpening stage, so there is no sharpening control.
- During a live stream, pinches also reach the game as usual.

## Logs

```
DIAG golden t_ms= step=show set= eye_px=WxH density= rq= world_locked= overlays= sha_ok=
DIAG golden t_ms= step=setting set= key=world_locked|repin|rq|overlays|capture|exit value=
DIAG golden t_ms= step=settled set= rq_set= rq= frames= settle=rate_map|render_quality|timeout screen=
DIAG golden t_ms= step=hide set= eye_px= density= rq= world_locked= overlays= sha_ok=
```

`eye_px` is the server eye size, `density` the set's px/deg.

## Capture and measure

`CAP` runs the W33 Auto chart sequence on the golden display: head-locked, overlays off, one capture per quality step, the
quality restored after. Captures go to `Documents/diag/captures/golden-<set>-<stamp>-rq<q>/`; every `chartcap` line gains
`source=golden set=<set>`, and `capture.json` carries `golden_set` and a `golden` block (the settings in force: set, eye px,
density, rq requested and read back, lock, overlays, foveation, colour).

Pull the captures and logs, then:

```sh
python3 tools/diag/diag-report.py <pulled dir>                                   # "Golden frame" section
python3 tools/golden/golden-frame.py measure <pulled dir>/captures --set chart80 # per-patch against the golden
```

The diag-report `golden` topic lists one row per capture and eye (rq, rq_set, foveation, pose, finest contiguous correct
cpd, patch classes, lock, overlays, eye px, density, dir) and the golden lines.

## Limits

- Only the server frames are displayed. The 80 px/deg golden PNGs are the measurement truth on the Mac, not shown on the device.
- The server pair is the pre-codec frame (no HEVC artefacts) unless the set was encoded with `--codec hevc`, which makes
  `*.server.png` the ffmpeg-decoded frame (the pre-codec frames are kept as `*.server.raw.png`).
- One static frame: no motion, no frame pacing.
- CPU 4:2:0 conversion (above), not the hardware decoder's chroma siting.
