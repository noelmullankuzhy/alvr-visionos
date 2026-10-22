# Golden frame sets

`golden-frame.py` makes a reference image pair for the Vision Pro client that is sharper than anything the realtime
renderer produces. It also makes the server frame the client would receive for that pair. With both, reprojection,
smoothness and sharpness can be compared against a known truth on the device. Python 3.9+, standard library only.

```sh
python3 tools/golden/golden-frame.py render --set chart80                    # L.png, R.png at 80 px/deg (5.4 s/eye)
python3 tools/golden/golden-frame.py encode --set chart80 --point a100-axis-C # L/R.server.png (12.8 s/eye)
python3 tools/golden/golden-frame.py push --set chart80 --device <id>         # prints the devicectl command only
python3 tools/golden/golden-frame.py measure <capture dir> --set chart80      # W33 capture of the displayed set
```

The output goes to `tools/golden/out/<set>/{L.png,R.png,L.server.png,R.server.png,meta.json}`. `out/` is git-ignored.

At 80 px/deg each eye covers the full device frustum: a 12523x10046 PNG, about 2.1 MB for the chart. On the Mac
(review r1 timings) render takes 5.4 s per eye and encode takes 12.8 s per eye.

## Render

- **Grid.** Each eye is rendered on the device frustum from `tools/fov-matrix/avp-field.json`. L is left 1.7321, right
  1.0, bottom 1.1918, top 1.0; R is mirrored.
  - Pixels are square in tangent space at `--ppd` px/deg on the eye axis. At the default 80 that is 4583.66 px per tan
    unit and 12523x10046 per eye.
  - Pixel x = (tan_x + left) * k and y = (top - tan_y) * k.
- **`--content chart`** draws the 24 patches of `ResolutionChart.swift` GratingChart.
  - Positions, cpd, bars and Fick-corner quads are the same as the device chart. Patch rects equal the chart's NDC
    rects, and this is tested.
  - Bars are drawn with exact area coverage in linear light, so 20 cpd is 2 px per bar at 80 px/deg with no aliasing.
  - Also drawn: a cross at every 1 deg of az/el, axis ticks (longer at 5 and 10 deg) and the eye-axis cross.
  - The 7-segment labels are not drawn.
  - The chart is head-locked at infinity, with temporal mirrored per eye as on the device.
- **`--content image --image P.png`** puts the photo on a plane `--distance` m ahead and `--plane-width` m wide.
  - The plane is centred between the eyes, and each eye sits at -+`--ipd`/2.
  - The photo is area-averaged by an integer factor, then sampled nearest.
  - This assumes the view axes are parallel to the head's forward direction.

## Encode

The server frame is built at `--render WxH` with `--foveation cx,cy,rx,ry,shx,shy`, or from a `--point` row of
`tools/fov-matrix/points-chart-avp.tsv`. The point sets the render size (render scale x 3648x2912), the foveation and
the fov scale.

- **Mapping.** The foveated compression is the exact algebraic inverse of the client's expansion:
  - `ALVRClient/Shaders.metal:148-189` (`decompressAxisAlignedCoord`; each edge is a quadratic root, so its inverse is
    that quadratic).
  - `:136-145` (the R eye's x is mirrored).
  - `:217-221` (side-by-side halves).
  - The aligned values come from `FFR.swift:79-102`, through `fov-overlay.py fov_axis`.
- **Pixels.** Each coded pixel is the area average of the golden over its footprint, in linear light.
- **Layout.**
  - L content is at x [0, opt) and R content at x [coded - opt, coded).
  - Content fills rows [0, opt_y).
  - Padding is black.
- **Tests.**
  - The inverse matches ALVR's server map (`fov-overlay.py u_of_c`).
  - The client mapping matches the real shader within 1e-4 on `fixtures/ffr-expand-a100-axis-C.tsv`. That file is
    written on the Mac GPU by `sh tests/swift/run-tests.sh DiagFFRExpandFixtureTests`, which runs
    `decompressAxisAlignedCoord` from Shaders.metal on a 9x9 grid per eye. Without the file the test skips.
  - A round trip through an emulated client (shader maths plus a bilinear sample) puts every pixel within one target
    pixel. The exceptions are pixels whose sample point is past the outermost coded pixel centre, where the sampler
    clamps.
- **`--codec hevc --bitrate 500M`** runs a local ffmpeg round trip when `ffmpeg` is on PATH. It encodes one frame of L|R
  side by side at `--fps`, decodes it, and keeps the pre-codec frames as `*.server.raw.png`. Without ffmpeg the step is
  skipped with a message.

## meta.json

meta.json records:

- the frustum tangents, density and golden sizes
- the render size, fov scale and points row
- the foveation settings and aligned values
- the server size and layout
- the codec status
- the sha256 of every PNG
- the chart patches per eye (NDC and golden px rects)
- overlays as data: the frustum rectangle (identity), the eye axis, and a lens outline polygon per eye (every 5 deg:
  ray, ecc, tan, ndc, px)

Every overlay element has an `ndc` form next to its px and tangent forms. It is in eye NDC as the client draws:
`CornerTangents.ndc` (`ALVRClient/Diagnostics/CornerChart.swift:69-71`), with +y up and the frustum at [-1, 1].
Chart patches use `GratingChart.quad(...).rect` (`ResolutionChart.swift:212-230`). Golden px =
((x + 1) / 2 * width, (1 - y) / 2 * height).

The lens outline comes from W34's `BoundaryDotsLensReference` table in `ALVRClient/Diagnostics/BoundaryDots.swift`
when the client has one. Otherwise it comes from the 21 Oct dots log
(`evidence/device-20261021/diag-20261021T152509Z.log`, dots_summary L over Both). R is L mirrored,
R(phi) = L(180 - phi).

## Measure

`measure` reads a W33 chart capture (capture.json `chart_capture` plus PNG). Per patch it runs the W33 bar counter
(`diag-report.py` count_bars / classify_bars). It also estimates a Gaussian PSF FWHM from the bars' fundamental
modulation, in linear light, against the golden's own pixel box. It prints, per setting / eye / position /
orientation:

- the finest cpd with it and every coarser patch correct
- the median PSF in deg

It needs W33 (`feature/chart-autocapture`) merged into `tools/diag/diag-report.py`; `GOLDEN_COUNTER=<file>` points at
another copy.
