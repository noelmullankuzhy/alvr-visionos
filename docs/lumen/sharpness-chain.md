# Sharpness chain: where the client loses band sharpness

Chart matrix m7 (simulator, 100 Mbps): the server render is exact (band 51.5 px/deg measured = predicted, PSF 0), but the
client drawable reaches only about 0.68 of the predicted band sharpness (f070 38.7 vs 58.0, f060 43.8 vs 64.6, f100 29.0 vs
45.3 stream px/deg) with a PSF of 0.05-0.08 deg. This change measures each client stage separately, so the loss can be
assigned to a stage instead of being inferred.

## What is captured

A streaming capture (`capture.request`, or `ALVR_DIAG_CAPTURE_AFTER_MS`, triggered as before) now also writes, for each eye,
two stage images drawn by the stream's own fragment shader, with the same decoded planes, sampler and colour constants
(`Renderer.diagStreamStageTargets`, `DiagStreamStages`):

| stage | file | size (m7) | what it is |
|---|---|---|---|
| decoded | `stage-decoded-<eye>.png` | 2432x1856 per eye (coded) | the eye's half of the decoded frame at 1:1, FFR off. Pixel centres land on luma texel centres, so the only resample is the chroma upsample |
| expanded | `stage-expanded-<eye>.png` | 3648x2912 (render) | the stream's FFR decompress (`decompressAxisAlignedCoord`) at the stream view size, no warp |

They go into `capture.json` under the new keys `stages` (one entry per image: `stage, eye, png, width, height, pixel_format,
encoding, sampler{min_filter, mag_filter, mip_filter, address, coord}, source{ffr, uv_rect, planes[{format, width, height}],
chroma_subsampling, shader, vertex, decoder_pixel_format}`) and `resample_chain` (the steps below). Stage images never go into
`slices`, so the drawable tools are unchanged. The client never holds an expanded texture: it decompresses and warps in one
bilinear sample. The expanded image is therefore a diagnostic re-render of the expansion step alone. It adds a bilinear tap at
the band's sub-pixel phase that the real path does not have, so read its added PSF as an upper bound.

Cost per capture (debug path only): four extra private textures (about 2 x 42 + 2 x 18 MB at rgba16Float) and two pipeline
builds. The capture write takes longer on the simulator, so the runner gets a longer `--capture-timeout` (below).

## Resample chain at the eye axis (m7 settings)

Assumptions: drawable 3840x2160 per view, tangents 1/1/0.5625/0.5625, identity rate map, so 33.5 px/deg at the axis on both
axes (Nyquist 16.8 cycles/deg). Render 3648x2912, foveation 0.5,0.45,3,3 (the axis lies in the 1:1 band at all three points,
including f070-centred's shift). Every stream sampler is `mip_filter::none, mag/min linear, clamp_to_edge, normalized`.
"MTF" is the stage's response at the drawable Nyquist, 16.8 cycles/deg. "FWHM" is the stage's own blur in degrees. Both are
modelled for the x axis, with the y axis in brackets.

| # | resample | filter | scale at the axis: f060 / f070-centred / f100 | FWHM deg, f060 / f070 / f100 | MTF at 16.8 c/deg, f060 / f070 / f100 |
|---|---|---|---|---|---|
| 1 | decode_chroma: 4:2:0 chroma to the luma grid (server subsample, then bilinear upsample in the stream shader; private YCbCr formats do it in the driver's sampler) | bilinear, 2x magnification | 2:1 on both axes | upsample alone 0.038 (0.027) / 0.044 (0.031) / 0.063 (0.044); the server's 2-px chroma box comes on top | 0.21 (0.50) / 0.10 (0.37) / 0.00 (0.10) |
| 2 | ffr_expand: coded to render | (same sample as 3) | 1:1 in the band (edge 3:1 magnification) | ~0 at the axis | ~1.0 |
| 3 | warp: render to drawable, in the same bilinear sample as 2 | bilinear, no mipmaps | minifies x 1.58 (y 2.25) / 1.36 (1.93) / magnifies x 0.95, y minifies 1.35. Minification > 1 with no mip aliases rather than blurs | 0.019 (0.013) / 0.022 (0.016) / 0.031 (0.022) (triangle, one source px) | 0.71 (0.85) / 0.63 (0.80) / 0.36 (0.62) |
| 3a | drawable pixel grid (33.5 px/deg) | box, 1 drawable px | none | 0.030 | 0.64 |
| 4 | compositor: drawable to display panel (rate map, lens) | unknown (system) | simulator: identity rate map | not capturable from the app | not capturable |

Quadrature sum of 1 + 3 + 3a on x: f060 0.052, f070 0.058, f100 0.076 deg. The m7 drawable measured 0.06 deg at f070-centred
(0.059 deg with the chain's deconvolved estimator on the m7 capture).

**Which stage should dominate:** decode_chroma (the 4:2:0 chroma), and so the decoded stage. The chart metric is
G − max(R,B), a colour-difference signal, so it is limited by chroma resolution, which is half the luma resolution. At
f070-centred the chroma upsample alone is 0.044 deg (before the server's subsample filter). The warp tap plus the drawable
grid come second, about 0.037 deg together. The warp's minification (1.4-2.3:1 with no mipmaps) aliases rather than blurs.
FFR expansion is 1:1 at the axis. This is a prediction: the chain run decides it. If the decoded row shows most of the PSF,
the loss is encode-side (4:2:0 and compression), not client sampling. A luma-only chart metric would then isolate the warp.

## Chain table

`fov-overlay.py chain` measures band sharpness on every stage in that stage's own pixels:

- render: the dump's `chart-<eye>.png`;
- decoded: the coded geometry (`EncodedAxis`);
- expanded: the render geometry;
- drawable: the slice with its rate map and pose.

All four use the stream tangents and foveation from `meta.json`. Each stage uses the same band lines: only lines found in
every measured stage. Columns:

- `grid px/deg`: the image's own sampling at the line;
- `pred px/deg`: the stream's coded px/deg, the prediction every stage shares;
- `meas px/deg`: pred x nominal / FWHM;
- `PSF deg`: the Gaussian FWHM that widens the box line to the measured FWHM (deconvolved, so exact for a box line; the drawable mode's quadrature figure reads lower);
- `added PSF deg`: this stage's PSF over the previous measured stage's, in quadrature.

Follow-ups (deferred in review r1): the drawable's `added_psf_deg` is computed against the expanded stage, which the drawable
is not drawn from (the client expands and warps in one sample from the decoded planes), so read it against the decoded row
too; and there is no luma-only metric yet to separate warp sampling from the chroma loss.

`dominant:` is the stage that adds the most. A missing stage prints `not captured` (for example, the simulator draws one
view, so the R drawable is absent). `--out-json` keeps the rows, the per-stage lines and `resample_chain`.

## Stream MTF50 vs display ceiling

The fov-matrix row (`fovmatrix.py row`) carries two sharpness numbers. They measure different paths and respond to
different settings, so they cannot be compared one for one.

| | stream MTF50 (`centre/nose/temple/up/down_mtf50_cpd`) | display ceiling (`display_ceiling_cpd`) |
|---|---|---|
| source | the server's angle chart, rendered, encoded, decoded and FFR-expanded: the capture's `stage-expanded-<eye>.png` | the W33 resolution chart, drawn by the client itself (no stream) |
| measured by | `tools/fov-matrix/stream_mtf.py`, every captured point | W33 by eye (22 Oct: 17 cpd correct everywhere, 20 aliased); a constant in `avp-field.json` |
| responds to | server fov scale and render size (px/deg), foveation (band size, edge ratio), bitrate and encoder settings, 4:2:0 chroma, decoder, FFR expand | client render quality, drawable size, rate map, compositor and panel |
| does not see | the warp, the drawable, the compositor, the panel | anything on the server, the encoder or the decoder |

What the stream number is:
- MTF50 in cycles/deg of the expanded stage, the render grid, where px/deg comes from `meta.json` tangents.
- It is an edge method on the chart's axis-aligned green vertical lines.
  - Centre: the 0 deg line, 7 px.
  - Nose / temple: the ±15 deg lines, 5 px.
  - Up / down: the 0 deg line at e = ±15 deg.
  - Edges run across x and are averaged down ±4 deg of rows, skipping the crossings.
- The signal is linear luminance. The magenta horizontals carry almost no luma contrast, so only horizontal MTF is
  measured.
- Each edge's ESF difference is its LSF; |DTFT| gives the MTF; the two edges of a line are averaged.
- The chart has no slant and no bars. So there is no ISO 12233 oversampling, and the 20 deg / 3-px lines cannot be used
  (their edges overlap). The 15 deg lines stand in for 20 deg.
- The number includes the pixel aperture: the server's pixel-exact chart reads 1.0 to Nyquist (`>N`).
- `<x` marks an edge whose line never reaches the chart's line level (green, 0.7152 linear luminance). The blur is then
  wider than the line, and x is an upper bound.

How to read it against the ceiling:
- The stream number is the limit of what reaches the client.
- The ceiling is the limit of what the client can show.
- The eye sees roughly the lower of the two, further reduced by the warp.

22 Oct device run (avp1, 100 Mbps), mean of L and R:

| point | centre | nose | temple | up | down | ceiling |
|---|---|---|---|---|---|---|
| a100-asrun | 6.6 | 7.1 | 7.1 | 6.6 | 6.7 | 17 |
| a100-centred | 6.7 | 7.1 | 7.1 | 6.7 | 6.7 | 17 |
| a100-wider | 6.6 | 7.1 | 7.2 | 6.6 | 6.6 | 17 |
| a085-asrun | 7.9 | 8.4 | 8.4 | 7.9 | 7.9 | 17 |
| a085-centred | n/a* | n/a* | n/a* | n/a* | n/a* | 17 |
| a085-wider | 7.1 | 7.6 | 7.7 | 7.1 | 7.1 | 17 |
| a070-asrun | 9.6 | <6.1 | 10.2 | 9.6 | 9.6 | 17 |
| a070-centred | 9.6 | 10.3 | 10.2 | 9.6 | 9.6 | 17 |

\* a085-centred's `dump/meta.json` holds the 1.0 tangents, but its chart was drawn at 0.85, so the 15 deg line is not at
the 1.0 column.
- `stream_mtf.scale_mismatch` checks for this on every eye. It requires both ±15 deg lines within 2 px of where the meta
  tangents put them.
- The 0 deg column does not move with scale, so without that check the row reads a plausible but wrong 6.7.
- On a mismatch, every MTF column is n/a and notes reads `mtf: meta scale mismatch`.
- On the right grid, its centre would read about 7.9, like a085-asrun.

Each point's result is cached in `capture/mtf.json`, keyed by the size and mtime of capture.json, meta.json and the
expanded PNGs. A summary rerun therefore skips the ~35 s decode.

Findings:
- In cycles/px, every edge reads about 0.25 or 0.32. Those are a two-pixel and a one-pixel transition.
- The value depends on the line's sub-pixel phase in the FFR expand: L and R differ by up to 1.5 cpd at the same point.
- So the cpd figure is mostly the render px/deg (fov scale) times about 0.29 cycles/px, roughly 40% of the 17 cpd
  ceiling.
- The a070-asrun nose edge (0.17 cycles/px, both eyes) is the only real blur seen. It sits outside that point's
  foveation band:
  - L frustum tan −1.212..0.7, centerSize 0.5, so the band is tan −0.73..0.22; the nose is at tan 0.27.
  - The centred point moves the band over it (10.3).

## GM commands

The GM runs the build, the simulator and the PC. From the clone root, on `feature/sharpness-chain`:

```sh
# 1. build and install this client on the simulator (as vr-proof-plan.md step 1; $SIM = visionOS simulator UDID)
DD=$(mktemp -d)
xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -destination "platform=visionOS Simulator,id=$SIM" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build > "$DD/build.log" 2>&1 && echo BUILD_OK
APP=$DD/Build/Products/Debug-xrsimulator/ALVRClient.app
for f in "$APP"/Frameworks/*.framework "$APP"/*.dylib "$APP"/PlugIns/*.appex; do [ -e "$f" ] && codesign --force --sign - --timestamp=none "$f"; done
codesign --force --sign - --timestamp=none "$APP"
xcrun simctl install "$SIM" "$APP"

# 2. GPU tests that need a Metal device (not available in the worker sandbox)
sh tests/swift/run-tests.sh DiagStreamStagesGPU
sh tests/swift/run-tests.sh DiagCaptureGPU

# 3. run the three points (f060-asrun, f070-centred, f100-asrun) at 100 Mbps; longer capture timeout for the stage PNGs
OUT=/Users/noel/Projects/Management/goals/rdr2-vr/evidence/chart-matrix-20261022/m8-chain
sh tools/fov-matrix/run-matrix.sh --points tools/fov-matrix/points-chain-sim.tsv --mode chart --out "$OUT" \
  --bundle-id alvr.client --build a80b982ae75a --capture-timeout 120

# 4. print the chain table per point (left eye: the simulator's drawable slice)
for p in f060-asrun f070-centred f100-asrun; do
  python3 tools/diag/fov-overlay.py chain --capture-dir "$OUT/$p/capture" --meta "$OUT/$p/dump/meta.json" --eye L \
    --out-json "$OUT/$p/overlay/chain-L.json"
done
```

`--build a80b982ae75a` is the m7 server build (from m7 `run.log`). Check in each `capture.json` that `stages` holds four
entries. If it holds none, the client log's `DIAG capture error=stages_unavailable why=...` gives the reason.

## Tests

```sh
/usr/bin/python3 -m unittest discover -s tools/diag -t tools/diag -p 'test_fov_overlay.py'   # SharpnessChain: synthetic stages
sh tests/swift/run-tests.sh DiagStreamStages                                                  # plans, records, sampler vs Shaders.metal
```

`SharpnessChain` writes a synthetic matrix point (`fov-overlay.py synth --kind chain --stage-psf a,b,c,d`): a render, decoded,
expanded and drawable image with a known cumulative Gaussian PSF on box lines. The chain recovers each stage's PSF within 10%.
