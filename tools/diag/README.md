# AVP diagnostic inputs (decision 65)

Tools only: no client changes, third-party packages, ffmpeg, downloads or device installation.
Run from the repository root on a Mac with Xcode selected and an available HEVC encoder.
The two entry scripts assemble shared `clip-policy.swift` and `clip-engine.swift`
into a temporary script and invoke the system Swift interpreter. The same policy
is compiled directly by the encoder-free Swift tests; the temporary script is removed.

```sh
swift tools/diag/make-hevc-clips.swift --out /tmp/avp-hevc
swift tools/diag/make-pq-clips.swift --out /tmp/avp-pq
```

Use fresh output directories. `--help` lists overrides: `--sizes WIDTHxHEIGHT,...`,
`--fps 90,120`, `--seconds 5`, `--bitrate 40000000` (bits/s).
Default stress matrix: 3840×2160, 5120×2880, 7680×4320, 3648×2912,
90/120 fps, five seconds each. Its moving luma ramps and bars change every frame.
Encoding runs as fast as the Mac permits; timestamps express the requested cadence,
not a measurement of Mac real-time throughput. VideoToolbox uses Main10 auto-level,
limited-range P010 (10-bit 4:2:0), real-time mode, no frame reordering, and a
one-second maximum keyframe interval. Bitrate is a target, not a strict cap.

PQ defaults: 1920×1080 at 30 fps, a 14-second full-field neutral step sequence,
a 40-second labelled split comparison,
and a five-second horizontal gradient from 0 to 10000 nits (linear in nits).
Decision 63 steps are 0.05/0.25/0.5/1/2/4/4.926 × 203 nits, held two seconds each:
10.15, 50.75, 101.5, 203, 406, 812, 999.978 nits. Limited luma is
`round(64 + 876 * ST2084(nits/10000))`; neutral chroma is 512. Tags on the pixel
buffers and encoder are BT.2020 / SMPTE ST 2084 / BT.2020 NCL (VUI 9/16/9).
These are source luminances, not claims about panel output or headroom. No
mastering-display or content-light-level SEI metadata is synthesized.
`--seconds` truncates or extends each clip; the final step is held on extension.

Use `swift tools/diag/make-pq-clips.swift --kind split --out build/pq-split`
for just `split-1920x1080-30.mov`. The left patch stays at 203 nits
(BT.2408 HDR reference white); `--reference-nits N` selects another reference.
The right patch holds 100, 203, 300, 400, 600, 800, 1000, then 203 nits,
five seconds each. A centred black gap occupies 2% of the width (rounded to
an even pixel count). Large `REF 203` and test-nits labels occupy a separate
black top band; digit height is at least 8% of the frame. Labels use 203-nit
PQ white and do not alter either measurement patch below the band.
The manifest schedule records start/duration, test/reference nits and limited
10-bit luma codes for both halves, plus band/gap geometry. Validate with
`swift tools/diag/check-clips.swift build/pq-split/pq-manifest.json`:
it decodes limited P010, checks interior grids on both halves and the gap on
every frame (±3 codes for HEVC), excluding labels and boundary ringing.

## PQ grid

Measure the HDR **video** path using 25 seamless square cells on black, in the
same snake reading order as the Metal EDR grid: A1→A5, B5→B1, C1→C5,
D5→D1, E1→E5. Row letters A–E sit left of the grid; column numbers 1–5
sit above it. Labels are neutral 100-nit grey, outside every cell.

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/build/clang-module-cache"
mkdir -p build/tmp
export TMPDIR="$PWD/build/tmp"
for area in 1 10 50; do
    swift tools/diag/make-pq-clips.swift --kind grid --area "$area" --range coarse --out "build/pq-grid/$area"
    swift tools/diag/check-clips.swift "build/pq-grid/$area/pq-manifest.json"
done
swift tools/diag/make-pq-clips.swift --kind grid --area 10 --range fine --lo 600 --hi 2000 --out build/pq-grid/fine
```

Each still is 1920×1080, 30 fps, 30 seconds, HEVC Main10, limited-range
PQ / BT.2020 with neutral chroma. These dimensions/cadence/duration are fixed.
`--area 1|10|50` selects total cell area as a percentage of the frame (default
10); labels are excluded from that area. `--range coarse` (default) gives 25
log-spaced values from 100 to 10000 nits. `--range fine` gives 25 log-spaced
values from `--lo` to `--hi` (defaults 600 and 2000 nits; require
0 < lo < hi ≤ 10000). Endpoints are included. Files are named, for example,
`grid-10-coarse-1920x1080-30.mov` or `grid-10-fine-1920x1080-30.mov`.
Use separate fresh directories for each run, including different fine bounds.

The continuous grid is exactly centred with cell side
`sqrt(frameWidth * frameHeight * area / 100) / 5`. Its requested area is exact.
Each shared boundary rounds to the nearest pixel, preserving seamless tiling;
raster cell widths/heights can differ by one pixel. The manifest records the
continuous geometry, actual raster bounds/area, every named cell's source nits
and limited 10-bit PQ luma code, and label bounds. Thus pixel quantisation is
explicit rather than silently claiming an exact integer-pixel area. The checker
independently reconstructs the layout and log sequence, decodes every frame to
limited P010, and checks an interior lattice in **every cell** (±3 codes), plus
the black surround (code 64), excluding labels and boundary ringing.
The cell body inset is `ceil(max(8 pixels, 20% of the continuous cell side))`,
which gives 8/19/41 pixels for the 1%/10%/50% grids. Each `GRID_BODY` line
reports the file, cell, sampled body mean code, expected code, maximum absolute
**individual sample** error, sample count and inset. Statistics aggregate the
interior lattice across all 900 frames; they are not a full-pixel body average.
Every cell's statistics print before the body tolerance is judged, including
cells that exceed ±3. Black-surround failures still stop immediately.
The checker entry script assembles `clip-inspection.swift` with
`check-clip-engine.swift`; the unit tests use that same inset/statistics policy.

Push the selected directory using `push-clips.sh`, reload clips in the PQ player,
and play in a **window** first. Follow the snake from dim to bright and record
the **first cell that stops getting brighter** relative to its predecessor,
including its name, manifest nits, area and playback path. Use a fine range to
bracket that transition. Repeat in **immersive** playback, keeping the viewing
conditions and apparent video size comparable. If every cell keeps brightening,
record that the knee lies above the tested range; do not infer a measured knee.
Compare the video result with the Metal EDR grid separately: decision 65o found
windowed AVKit brightening through 1000 nits against a 203-nit reference, while
the Metal layer stopped near 1.45× SDR white. Source PQ nits and perceived
plateaus do not directly measure panel luminance.

Grid and level encodes explicitly request
`kVTCompressionPropertyKey_Quality = 1.0`; successful manifests record
`encoderQuality: 1.0`. The average bitrate target remains the requested value
(default 40 Mb/s). Unsupported quality settings fail with the existing property
OSStatus diagnostic; visual/code accuracy must be checked after regeneration.
Existing GM clips can be checked with the new body inset before regenerating.

Encoder-free regression tests:
`sh tests/swift/run-tests.sh GridInspection`,
`sh tests/swift/run-tests.sh GridClip`, `sh tests/swift/run-tests.sh SplitClip`,
and `sh tests/swift/run-tests.sh ClipEncoding`.

## PQ level match

`level` provides a static cross-path brightness target: one centred 10%-area
square at the requested source nits, black surround, and the numeric nits label
in 100-nit grey in a separate black top band. It uses the same Main10 limited
PQ / BT.2020 encoding, fixed at 1920×1080, 30 fps, **60 seconds**. Continuous
area and pixel rounding follow the grid convention above.

```sh
swift tools/diag/make-pq-clips.swift --kind level --nits 203,400,600,800,1000,1500,2000,4000 --out build/pq-grid/levels
swift tools/diag/check-clips.swift build/pq-grid/levels/pq-manifest.json
sh tests/swift/run-tests.sh LevelClip
```

`--nits` accepts one value (default 203) or a comma-separated list, each greater
than zero and at most 10000. Filenames are `level-203-1920x1080-30.mov`, etc.
Each manifest entry records nits/code, continuous and raster patch geometry,
and label geometry/code. The checker reconstructs these independently and
checks patch interiors and black surround on every frame at ±3 codes,
excluding the label and boundary ringing. Select the same level in windowed
and immersive video playback and compare its apparent brightness with the
corresponding Metal target, recording both playback path and nits. The label
names the source luminance; it is not a panel measurement.

JSON manifests contain successful files, dimensions, fps, frame count, actual
compressed-sample average bitrate, requested bitrate, and the profile/tier/level,
chroma format and bit depths read from the encoder's actual `hvcC` configuration.
`levelIDC` is HEVC general_level_idc (e.g. 153 = level 5.1). Refused configurations
include the OSStatus/error; partial files are removed. A partially supported matrix
exits zero and retains the refusal list; no successful clips exits nonzero.
At defaults, target compressed output totals approximately 300 MB, below 2 GB;
custom rates/durations can increase that. Clips are `.mov` with HEVC samples.

## Network sender / receiver contract

```sh
python3 tools/diag/netprobe-send.py HEADSET_IP --mbps 150 --fps 90 --packet-size 1200 --duration 30
python3 tools/diag/netprobe-send.py HEADSET_IP --mode tcp --duration 30
sh tools/diag/pull-diag.sh 'DEVICE NAME OR ID' /tmp/avp-diag-logs
```

Port defaults to 9944; the AVP sink must already be listening. The Python file
uses only the Python 3.9 standard library and also runs on Windows. UDP sends
one burst per frame, pacing from absolute monotonic deadlines. Fractional byte
budgets carry between frames. Packet size is a **maximum UDP payload**; a frame's
budget is distributed over packets so every packet can hold its header. Rate
includes the diagnostic header, excludes UDP/IP/link headers. Overdue frames
are skipped instead of accumulating catch-up bursts; late frames are reported.

Every UDP packet starts with this 28-byte network-byte-order header (`!4sQQIHH`):

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | 4 bytes | ASCII `AVPD`, protocol version defined by this magic |
| 4 | uint64 | Packet sequence, starts at zero per run |
| 12 | uint64 | Sender monotonic nanoseconds immediately before send |
| 20 | uint32 | Frame ID, starts at zero (may skip if sender is late) |
| 24 | uint16 | Packet index within frame, zero based |
| 26 | uint16 | Total packets in frame |
| 28 | bytes | Zero-filled padding to the packet's payload size |

Monotonic clocks on different hosts have different origins. Derive relative
jitter/loss from these fields; absolute one-way latency needs clock alignment.
TCP is deliberately unpaced bulk (ignores rate/fps/packet-size), zero bytes with
no message framing. Its summary `packets` counts send calls, which may be partial,
not TCP segments. JSON summaries report locally accepted bytes, actual elapsed
time, offered Mb/s and late frames; they do not establish receipt/loss at the sink.
Socket timeouts/errors produce a nonzero exit. The puller targets the paired
app's `uk.lumenio.alvr` data container, `Documents/diag`, and preserves logs on device.

## Corner chart mirror comparison

```sh
sh tools/diag/capture-mirror.sh -i 2 -o /tmp/avp-mirror
sh tools/diag/capture-mirror.sh -l
```

The client's corner chart (Diagnostics on, Corner chart setting, no stream) is
head-locked and works in mixed immersion. Left is cyan, right is magenta, with a
large L / R at the centre. Rings are rectangles at 100, 95, …, 55, 50% of that eye's
tangent extents. In each corner the straight cuts run 100, 95, …, 35, 30%.
In quadrant-normalised units the drawable corner is (1,1); cut p is x+y=2p/100,
clipped to the drawable, and touches ring p's corner. Axis numbers label rings;
stacked diagonal numbers label cuts. Ring labels alternate on either side of each
axis spoke: 100/90/80/70/60/50 on one side, 95/85/75/65/55 on the other. This keeps
all rings, including 50/55/60, readable without overlap under peripheral foveation. Every stroke is at least 3 physical pixels
and every character at least 24 physical pixels tall, sized from the frame's
per-eye rasterization rate map (identity without a map). The once-per-eye
`corner eye=… view=… stroke_min_logical_px=… stroke_max_logical_px=…` line records
the logical stroke range; 0.25 physical/logical needs a 12-logical-pixel stroke.

Keep the headset's fit and head pose steady. Record **8 marks per eye**, L then R
in Both eyes mode: **0 (right side), 45 (upper-right cut), 90 (top), 135
(upper-left cut), 180 (left), 225 (lower-left cut), 270 (bottom), 315
(lower-right cut)**. Find the outermost visible side or cut. Quick right pinch
steps out, quick left pinch steps in; hold right for at least 0.5 s to record and
advance, hold left to go back. Gamepad: up/right = out, down/left = in, A = record,
B = back. The white highlight follows the selected side or straight cut; the
status reads e.g. `L 45 70`. Side selection stops at 50; cuts continue to 30.

Marks log `DIAG corner eye=… pos_deg=… ring_pct=… kind=side|cut tan_x=… tan_y=…`.
For a cut, the tangent point is its intersection with the diagonal, not a polygon
vertex. After eight marks, `corner_summary eye=… shape=octagon sides=… cuts=…
visible_area_frac=…` logs the raw percentages: sides in right,top,left,bottom order;
cuts in q1,q2,q3,q4 order (upper-right, upper-left, lower-left, lower-right).
Recompute the area by clipping the side rectangle with all four cut half-planes,
then dividing by drawable area 4 in normalised units. A cut at or beyond its
quadrant's side-rectangle corner removes nothing. Sides 100 with cuts 100 / 75 / 50
give fractions 1 / 0.875 / 0.5; sides 55 with cuts 55 give 0.3025.
`diag_floor=true` flags any diagonal mark at or below 50 (the ring floor), even
though cuts extend further inward. No visible-area API is available in visionOS
27.0; these are subjective marks. The report supports both this eight-mark
procedure and older sixteen-spoke logs, retaining their original shape fields.

Mirror My View currently shows the left eye (cyan L). Mirror captures compare
with left-eye marks only and have their own crop, so they do not measure the
panel's visible area. Mirror to this Mac from Control Centre, then use the capture
script above. It captures the largest window matching `-w` (default `airplay`;
use `-l` to list windows), every `-i` seconds as `mirror-<UTC>-<n>.png`, with times
and window IDs in `index.tsv`. Missing windows, Screen Recording permission, or
capture failures cause an error. A smaller mirror crop than the headset marks is
expected; a larger one suggests conservative marks.

## Validation

```sh
/usr/bin/python3 tools/diag/test_netprobe.py
/opt/homebrew/bin/python3 tools/diag/test_netprobe.py
sh tools/diag/smoke.sh
sh -n tools/diag/pull-diag.sh
sh -n tools/diag/capture-mirror.sh
sh tools/diag/capture-mirror.sh -i 0.5 -n 3 -o /tmp/avp-mirror -c
```

`-c` checks the capture arguments (whole-number `-n`, positive decimal `-i`) and
exits without building or capturing. The window lister's source, binary, compiler
temp, module cache and logs live in `<output>/.scratch`, removed at exit.

Python defaults test the wire header, fractional rate/pacing math, sender loop
with a deterministic clock/socket, and JSON summary without opening sockets.
Optional real TCP/UDP integration tests use loopback only:
`DIAG_LOOPBACK=1 /usr/bin/python3 tools/diag/test_netprobe.py` (repeat with Homebrew).
The smoke script generates three 640×360, 30 fps, one-second clips in a temporary
directory, checks both manifests against the files' actual format descriptions
(Main10, 4:2:0, 10-bit, PQ colour tags, dimensions, level, duration and sample
count), then removes the clips. It fails when encoding or inspection fails.
The same checker can inspect full runs:
`swift tools/diag/check-clips.swift /tmp/avp-hevc/hevc-manifest.json /tmp/avp-pq/pq-manifest.json`.

If the execution sandbox blocks the default Swift module cache, set
`CLANG_MODULE_CACHE_PATH` to a writable scratch directory; smoke does this itself.

Validation in the authoring sandbox (2026-10-21): Python tests passed on both
interpreters (five tests each, two opt-in integrations skipped); shell syntax
passed. Loopback integration was attempted but bind is denied by sandbox policy.
Swift encoder and checker compile, but file smoke **did not pass**: VideoToolbox
only enumerates RGB/JPEG encoders, no HEVC, and creation returns -12908 at every
requested matrix point and 640×360. This is not an AVP decoder limit measurement.
Run the smoke command above outside that restricted environment before use.
The required visionOS Xcode build was attempted; it fails on missing provisioning
profiles and the absent `ALVRClient/ALVRClientCore.xcframework` (the initial default
DerivedData location was also unwritable). No app files were changed.

## M2 / M3 brightness diagnostics

```sh
sh tools/diag/push-clips.sh 'DEVICE NAME OR ID' /tmp/avp-pq
```

Copies the directory contents into `Documents/diag-clips` in the installed
`uk.lumenio.alvr` app's data container, preserving existing files. Enable
Diagnostics and restart (or launch with `ALVR_DIAG=1`), then open **Brightness
diagnostics (EDR ramp / PQ player)** under Advanced Settings, without a stream.
The controls are absent when diagnostics is off. Keep the controls window to
the side of the measurement area; both diagnostic spaces use mixed immersion.
Exit a diagnostic before entering a stream. Stop/exit also releases the player.

**PQ split comparison:** Reload clips and select `split-1920x1080-30.mov`.
Compare the broad patch areas below the labels, using the left `REF 203` as
the fixed reference. Above 203 on the right, **right brighter than left means
visible headroom; equal means clipped**. The 203-nit holds should match, and
100 should be darker. Record the highest distinguishable level in both window
and immersive playback. These observations assess the playback path; source
nits do not measure physical panel luminance. With a custom reference, compare
against that labelled value instead. The player logs zero-based split steps
0–7 at five-second boundaries, alongside clip, path and current playback time.

**EDR ramp:** unfoveated, per-eye `rgba16Float`, extended-linear Display P3.
The separate fragment writes neutral values directly, with opaque alpha and
no app shoulder or gamut/transfer conversion. Patches and their opaque black
surround both write finite reverse-Z depth for a two-metre view plane, derived
from each drawable view's current scene-aware projection (see
[WWDC24 10092](https://developer.apple.com/videos/play/wwdc2024/10092/)).
Pixels outside the view's viewport remain transparent with zero depth.
Layout areas are fractions of
each eye's drawable viewport, not calibrated fractions of the visible optical
field. Centre patches have a black surround; split has unity on the left;
checkerboard is 8×8 with equal black/bright areas. Pinch the ramp or tap Next
to advance through 0/0.25/0.5/1/1.25/1.5/1.75/2/2.5/4, looping. Automatic mode
holds each submitted level for 4 seconds, or 60 seconds with Sustained selected.
Manual Next overrides the timer. Changing settings restarts that level's timer;
late frames advance once instead of skipping unpresented levels. The mark
button records the most recently submitted value/layout as a visual threshold.

`Diag.log` keeps decision 65's timestamp-first format and key/value fields:

```text
DIAG edr t_ms=1234 step=9 value=4.000 layout=10% mode=auto hold_s=60
DIAG edr t_ms=5678 mark=true value=4.000 layout=10%
DIAG pq t_ms=9000 path=window clip=pq-steps.mov current_s=2.000 step=1 rate=1.000 waiting=none
```

**PQ player:** choose the generated `steps` clip, then Play in window (AVKit
VideoPlayer) or Play immersive (RealityKit VideoPlayerComponent). Each launch
starts the same selected file from time zero; only one presentation is active.
Logs include clip/path, `eligibleForHDRPlayback`, `availableHDRModes` (deprecated
but recorded as requested), actual item format transfer/primaries, status/error,
and media time/rate/waiting reason every 250 ms. Status and metadata errors carry
the originating item's immutable clip/path, including late callbacks after a
new playback begins. `step` is zero based at 2-second
boundaries for filenames containing `steps`, with step 6 held past 14 seconds,
matching the generator. Other clips log step -1; use media time and their own
manifest. These are media-clock samples, not measured photon presentation times.
Record headset brightness, OS/model, ambient light, fit and thermal/power state
alongside logs. Device photometry or Noel's visual comparison remains necessary
to establish actual brightness; playback eligibility does not measure headroom.

## Render quality and hardware codec audit (D6)

With Diagnostics enabled after an app restart, select **Render quality sweep**
under Advanced Settings while disconnected, then enter the Metal immersive
space. RealityKit does not run this probe. The centre target overlays the idle
background: a 256×256 logical-pixel square with alternating one-pixel black/white
vertical lines on the left and horizontal lines on the right. Keep the headset
still and fixate the centre to compare fine-line resolution. Raster-rate mapping
is retained; these are logical screen pixels, not a claim of optical PPD.

Each of 0.5, 0.75 and 1.0 gets 3 seconds to settle and 20 seconds of measurement.
Values above the configured allocation ceiling are skipped. A run takes 69 seconds
at the current 1.0 ceiling, then restores the previous runtime quality. Starting
a stream, disabling the switch, pausing or leaving the space cancels and restores.
Toggle off/on to repeat a completed run. Older systems log `rq unsupported=1`.
Each result line identifies drawable and view, texture and raster-map dimensions,
actual quality read back, full-command-buffer GPU p50/p99, GPU deadline misses
(including command-buffer errors), submitted frames and end-of-step process
footprint in MiB. Settle frames are excluded; delayed GPU completions stay with
their original point. Percentiles use nearest rank, bounded to 4096 GPU samples
per point (enough for 20 seconds at 120 Hz). Timing covers the background and grid.

At Diagnostics start, `codec` lines query HEVC, AV1 and H.264 hardware support.
HEVC format session checks require real parameter sets generated on the Mac:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/clang-module-cache" xcrun swift \
  -module-cache-path "$PWD/build/clang-module-cache" \
  tools/diag/make-codec-audit.swift ALVRClient/Diagnostics/codec-audit.json
```

Rebuild the client after regenerating this bundled manifest. The generator
attempts one 64×64 frame of 10-bit 4:2:0, 4:2:2 and 4:4:4, checks the encoded hvcC
chroma and both bit depths, then extracts VPS/SPS/PPS. Encoder refusal or conversion
is recorded with its status/reason; no fabricated descriptions are substituted.
The checked-in manifest was regenerated by the GM outside the sandbox and
contains verified parameter sets for all three chroma formats. The loader tests
check JSON decoding and CoreMedia format construction, including encoded chroma
and bit depth; actual required-hardware sessions run on the headset. `refused_by_encoder=1` describes this
fixture provenance, not the headset decoder. Missing fixtures log `fixture_missing=1`.
A successful session establishes acceptance of that small format description;
it does not establish maximum decode resolution, rate or sustained throughput.

## M7 / M8 on headset

Enable Diagnostics in Advanced Settings and restart the app (or launch with
`ALVR_DIAG=1`). Advanced Settings then shows **Decode bench**, a port field
(default 9944), **TCP bulk**, **Net sink**, **Stop**, and run status. These controls
and their resources are absent with diagnostics off. Stop the stream first;
a stream start synchronously closes the network listener and waits for decoder
callback drain and all session invalidations, including cancellation during creation.
The gate refuses new diagnostic starts throughout teardown. Stop has the same guarantee.

Generate stress content with independent moving luma/chroma noise to fill high
bitrate requests, then copy a clip directory to the installed client:

```sh
swift tools/diag/make-hevc-clips.swift --out /tmp/avp-noise --content noise --bitrate 150000000
sh tools/diag/push-clips.sh 'DEVICE NAME OR ID' /tmp/avp-noise
```

`--content default` preserves the moving ramps/bars. Noise uses deterministic
frame-seeded xorshift samples across the limited luma/chroma range. Noise defaults
to targeted output: a supported VideoToolbox rolling data-rate cap is requested,
and the achieved compressed-sample bitrate must be within ±15% of the request
with **zero dropped frames**.
A miss triggers re-encoding (up to eight attempts), bisecting noise amplitude on
overshoot **or any dropped frame**, or increasing the encoder bitrate hint on
undershoot only when no frames were dropped. A successful callback with a nil
sample, or a `frameDropped` flag, counts as a drop; nonzero OSStatus remains an
error. Even a trial that dropped every frame feeds calibration rather than
failing movie finalization. A clip that still
misses is refused and deleted, never published as meeting its target. The manifest
records `rateMode`, `rateLimited`, `noiseAmplitude`, `encoderBitrate`,
`dataRateLimitApplied`, `encodeAttempts`, `bitrateTolerance`, `requestedFrames`
and `droppedFrames`. `frames` counts encoded frames; encoded + dropped must equal
requested. The bounded `calibration` array preserves each attempt's achieved rate,
amplitude, encoder hint and drops. Targeted clips with persistent drops are
refused, with `droppedFrames` recorded in the refusal, and their files removed.

Use `--content noise --stress` explicitly for uncapped overload: the manifest labels
it `rateMode=overload`, `overload=true`, `rateLimited=false`. This mode retains the
bitrate hint and full-amplitude noise but applies no hard cap or tolerance check;
its achieved rate may differ substantially. Partial output is allowed and its
`droppedFrames` remains visible; an all-dropped run cannot produce a playable
movie and is refused with the drop count. It is not a calibrated target clip. Encoding
is CPU-heavy on large noise inputs; generation speed is not a decoder result.
Both `achievedBitrate` and the existing `bitrate` manifest field contain measured
compressed sample bytes × 8 / media duration. Compare these with `requestedBitrate`;
an encoder target is not evidence that the requested bitrate was reached.

**Decode bench** reads each MOV/MP4/M4V in Documents/diag-clips, in filename order,
and runs 1/2 independent hardware-required sessions in max/paced modes, without
presentation. The shared client output attributes leave SDR in the native format
and request explicit full/video-range 10-bit planes for PQ. Each session has at
most eight outstanding submissions; latency is submit-to-callback wall time,
quantiles use nearest rank over bounded histograms (precision below), and fps/pixel rate aggregate both sessions over their
common wall interval (coded dimensions, not visible eye regions). Paced runs
include the last frame period. Drops are submitted minus successful callbacks;
errors, actual output fourcc(s), hardware property readback, dimensions, source
cadence and depth limit are logged through Diag. Err -1 is an outstanding-slot
stall, -2 a reader failure, -3 hardware readback false; VT errors retain OSStatus.
Cancellation waits for outstanding callbacks and session invalidation before admission reopens. Inspect every trial's `err` and `hw`;
the UI's completion message alone does not establish hardware acceptance.

**Net sink** listens on IPv4, UDP unless TCP bulk is selected. Each run lasts up
to 60 seconds, or until Stop, leaving the panel, or a stream starts. Use one sender
run per sink run; start the sink before the sender. Specify `--port` on the sender
if changed. If ALVR or another listener owns 9944, select another port on both.
UDP pins the first valid sender address/port and counts foreign/malformed packets
separately. TCP consumes unframed bulk and reports throughput only.

`DIAG net` reports once per second and once with `summary=true`. `mbps` includes
UDP diagnostic headers, excludes UDP/IP headers; periodic rates use the elapsed
report interval. Summary rates use first-to-last valid reception (`active_seconds`),
excluding setup/stop idle time. All other counters/distributions are cumulative:

- `loss`: highest sequence + 1 minus unique received packets; includes leading
  loss and repairs late arrivals. Trailing loss cannot be known without a sender
  end marker. Duplicates do not repair loss. `reorder` counts unique arrivals
  below the highest sequence. History retains at least 65536 sequence numbers;
  older arrivals count as `stale` and remain lost. At most 256 incomplete frames
  are tracked; incomplete/evicted frames never enter completion distributions.
- `jitter_ms`: RFC3550-style EWMA of absolute changes in (receive time − send
  time), alpha 1/16, using unique arrivals in reception order.
- `spread_p95_ms` / `spread_p99_ms` and `burst_tail_p95_ms` / `burst_tail_p99_ms`:
  nearest-rank histogram estimates of first-to-last reception spread of **complete** frames, including
  reordering. They measure delivery spread, not absolute one-way latency.
- `owdv_ms`: max minus min packet transit; `owdv_p95_ms` / `owdv_p99_ms`:
  complete-frame worst packet transit relative to the minimum packet transit
  across the run. Sender/receiver clock offset cancels; drift can still contribute.

Completion spreads and decode latencies use fixed 0.125 ms histogram bins from
0 to 65536 ms; relative frame transit uses signed bins from -65536 to +65536 ms
around the first packet's transit. Quantization error is at most **0.0625 ms** for
an in-range percentile, regardless of sample count. Transit is rebased before
histogramming so unrelated host clock origins cannot consume its range. Completion
and decode totals are separate counters; no observations are retained or sorted.
Two network distributions use <13 MiB; one decode distribution uses <4.1 MiB,
unchanged after millions of samples. Block totals keep percentile queries bounded
to a short bin scan. `hist_error_ms` records the bound; `hist_overflow` counts
out-of-range observations, whose percentile ranks report `nan` rather than a
clipped measurement. The 60-second listener limit is not the memory bound.

Validation (no device required except the final measurement runs):

```sh
sh tools/run-tests.sh
sh tools/typecheck
/usr/bin/python3 -m unittest discover -s tools/diag -p 'test_*.py'
/opt/homebrew/bin/python3 -m unittest discover -s tools/diag -p 'test_*.py'
DIAG_LOOPBACK=1 sh tests/swift/run-tests.sh DiagSinkLoopback
```

The Swift tests cover parser golden bytes cross-checked against the Python sender,
loss/reorder/jitter and decode statistics, run exclusion/ownership, actual bench
compilation and shared SDR/PQ output requests. `test_noise.py` asserts >=2× the
bitrate of default content for a 640×360/30fps/1s clip at the same 20 Mb/s request.
It also checks ±15% and all 180 frames (zero drops) at
**3648×2912@90, 150 and 300 Mb/s** (two-second clips),
plus explicit overload labelling. `ClipEncodingTests` uses no encoder: it verifies
callback classification and the production calibration loop with fake encoded
results, including in-range/below-target/all-dropped trials, retry exhaustion,
overload drops and real encoder errors. Swift tests inject cancellation during session
creation and frame submission, hold callback drain and invalidation separately,
and feed one million completions/latencies through the bounded distributions.
It explicitly skips only HEVC creation refusal -12908. Swift and Python loopback
tests are opt-in; the worker sandbox denies bind. HDRGPUTests also cannot access
a Metal device there: use `SWIFT_SKIP_TESTS=HDRGPUTests sh tools/run-tests.sh`
for the remaining tests (the runner prints the explicit skip), and run the normal
suite, noise test, and both loopback suites outside that sandbox. Hardware decode
acceptance/throughput/format and real PC→AVP network tails remain device-only.

## Boundary dots

This separate **Boundary dots** button (decision 65h) appears beside **Enter
diagnostics** with Diagnostics on and no connection or active stream. Unlike the
Metal diagnostics button, it does not depend on the saved streaming renderer.
It opens `BoundaryDotsOffline`, a mixed RealityKit immersive space; a black,
unlit sphere at 11 m provides constant contrast behind the dots. Both offline
spaces reserve the same ownership state before opening; buttons and auto-enter
cannot take the immersive slot while either is opening, open, or dismissing.
A connection or stream arriving closes the space and retains ownership until
dismissal returns. It does not automatically open an online space. Failed opening,
**Done**, and a system/manual leave release ownership. Online Enter and streaming
rendering keep their existing paths. The lobby becomes transparent and ignores
input during dots measurement; its state remains alive so auto-enter stays consumed.

1. Turn on **Diagnostics**, restart the app, and leave the streamer disconnected.
   First enter and leave **Enter diagnostics** to capture `m5_view` projection
   tangents in this app session (the saved renderer must be Metal for that button).
   RealityKit dots do not manufacture CompositorServices projection measurements;
   without prior M5 values the report retains angular points and says **no data**
   for tangent percentages and area.
2. Choose **Boundary dots**. Keep a comfortable, steady head pose. Use a quick
   **right-hand pinch** on **L**, **R**, or **Both** near the fixation cross to
   select the eye label. Each eye keeps its own cursor and confirmed boundaries
   when switching back. Close the other eye yourself for L/R; Both labels a
   binocular observation, not two monocular measurements.
3. Look at a reachable dot until the system highlights it, then quick-pinch with
   the **right hand** to select the ray and cursor dot. A **yellow 1.6° ring**
   stays on the cursor independently of gaze. Wherever you look (including empty
   black space), a **left-hand quick pinch (< 0.5 s)** steps one dot **outward**;
   a **left-hand hold (>= 0.5 s)** steps one dot **inward**. Steps stop at 10° and
   70°. Actions occur on release, once per pinch; a cancelled pinch does nothing.
4. When the cursor reaches the outermost dot you can see, **hold the right-hand
   pinch for >= 0.5 s and release**, wherever you look, to confirm it white.
   Each ray has one boundary per eye; confirming again replaces that ray's old
   boundary. Quick right-pinch a highlighted confirmed dot to clear it. Repeat
   around all 24 rays (0° right, increasing counter-clockwise in 15° steps).
   The dim centre status shows eye, cursor ray/eccentricity and rays done.
   Use the centre cross between observations. The field follows your head;
   turning your head cannot bring an edge dot towards the centre. Gaze only
   needs to reach the starting dot on each ray; stepping and confirmation do
   not need an edge dot to highlight. If no starting dot on a ray can be
   highlighted, note a **tracker limit** separately and leave that ray unmarked.
   Quick right-pinch **Done** or leave with system controls to write all three
   eye summaries and return to the lobby.
5. Pull `diag-*.log` and run `diag-report.py` below. The **Boundary dots** section
   contains per-eye boundary tables, source references, and `visible_area_frac`.
   An area requires all 24 rays and valid tangents; no missing boundary is inferred.

Geometry: 600 dots lie at radius **10 m**, 25 per ray at eccentricities
10°, 12.5°, …, 70° from forward. Visible sphere diameter is 1.0° and collision
diameter is 2.2°. Nearest centres are 2.5° apart; the inner ring's adjacent rays
are about 2.60° apart. `BoundaryDotsTests` exhaustively checks all collision pairs
and checks the direction angles. At a representative 64 mm IPD, each eye is
32 mm from the head centre: its angular offset at 10 m is **0.183°**; the total
between-eye disparity is about 0.367°. Per the GM's clarification, 0.2° is the
**per-eye** target. It is well below the 2.5° radial dot spacing. Actual IPD,
device-vs-head origin, headset fit, eye cant and pose latency also limit accuracy.
The finite dot diameter, 2.5° radial quantisation, and 15° ray spacing limit
boundary accuracy; 70° is the field's ceiling, not a measured visibility cutoff.
Do not move the headset or change its fit between M5 capture and measurement.

Head locking and input: `BoundaryDotsScene.install` adds an ordinary `Entity`
directly to `RealityViewContent`. On **every `SceneEvents.Update`**, `followDevice`
queries the existing `WorldTracker.shared.worldTracking` (`WorldTrackingProvider`)
at `CACurrentMediaTime()` and copies `originFromAnchorTransform` onto that root,
without smoothing. All dot positions are local to it. Missing/untracked poses hide
the field on hardware; input is also rejected after connection/stream arrival.
There is no `AnchorEntity(.head)` in this implementation and therefore no reliance
on input support for privacy-protected head anchors. Each dot and control explicitly
has `InputTargetComponent(.indirect)`, `CollisionComponent`, and
`HoverEffectComponent`. The black backdrop also has indirect input and a sphere
collision shape, without hover. `SpatialEventGesture.targetedToAnyEntity()` reads
spatial-event chirality and timestamps, retaining each event's initial target
and start time until release. Left steps and right holds ignore the target;
short right pinches use the system-selected entity. Unknown chirality is ignored. This follows Apple's documented
[device-transform placement](https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform)
and [entity gesture requirements](https://developer.apple.com/documentation/realitykit/responding-to-gestures-on-an-entity).
The [update event](https://developer.apple.com/documentation/realitykit/sceneevents/update)
runs once per frame interval. The app does not estimate gaze or read hover identity.
In Simulator, when ARKit supplies no pose, a stationary root at `(0, 1.6, 0)`
permits pointer hover/click checks. This fallback is compiled out on hardware and
does not validate head-follow latency. GM device checks must verify head locking,
hover, yellow cursor persistence, both-hand timing, empty-space input and
confirmation at the centre and edge. Pointer tests cannot validate chirality or
establish tracker limits.

Each cursor action writes, for example:

```text
DIAG dots_session t_ms=100 event=begin radius_m=10.000 pose=device angles=projected_tangent
DIAG dots t_ms=101 eye=L action=cursor ray_deg=45.000 ecc_deg=60.000 yaw_deg=50.768 pitch_deg=50.768 via=gaze
DIAG dots t_ms=102 eye=L action=confirm ray_deg=45.000 ecc_deg=60.000 yaw_deg=50.768 pitch_deg=50.768 via=step
DIAG dots_summary t_ms=103 eye=L points=2 rays=0:30,90:32.5
DIAG dots_summary t_ms=103 eye=R points=0 rays=none
DIAG dots_summary t_ms=103 eye=Both points=0 rays=none
```

Actions are `cursor`, `step_out`, `step_in`, `confirm`, and `clear`.
`via=gaze` identifies cursor selection/clear; `via=step` identifies stepping and
hold confirmation. Cursor/step actions never contribute boundary vertices.
New logs replace same-ray confirms; old D11 logs without `via` still replay
multiple marks and use the outermost remaining confirmed dot.
`points` counts confirmed rays; `rays` is the sorted ray:outermost-eccentricity
list, sufficient to reproduce the polygon. Summaries are authoritative even if
earlier toggle lines are absent. Session markers prevent re-entry from merging
walks. Unsummarised confirmations are replayed with clears and reported as a
partial walk. Original lines are retained in the report.

For eccentricity `e` and ray `r`, the unit head/device direction is
`(sin(e)cos(r), sin(e)sin(r), -cos(e))`. Right/up are positive; logged yaw is
`atan2(x,-z)` and pitch is the **projected vertical angle** `atan2(y,-z)`, not
spherical elevation `asin(y)`. Thus tangent-plane coordinates are exactly
`tan(yaw)` and `tan(pitch)`. The report uses the latest preceding `m5_view` per
eye in the same app session, with tangents ordered left,right,bottom,top (view
0 = L, view 1 = R unless explicitly labelled). It reports signed percentages
`100*tan(yaw)/tan_right` on the right, `100*tan(yaw)/tan_left` on the left, and
the equivalent top/bottom percentages for pitch. A monocular simulator view does
not supply the missing eye's tangents. Both-labelled points are converted for
each available eye separately.

This is a **head-vs-eye-origin approximation**, without eye translation or cant
correction. For area, the affine drawable coordinates are
`u=(tan(yaw)+left)/(left+right)` and `v=(tan(pitch)+bottom)/(bottom+top)`.
`visible_area_frac` is the shoelace area in those normalised units (the drawable
has area 1), requiring all 24 outermost rays. Side percentages have different
scales on asymmetric frusta, so are not used directly for area. Values outside
the drawable are retained without clamping; an unexpected area above 1 exposes
the approximation or inconsistent measurements. Incomplete walks show **no data**,
not zero area. A visible-but-unhighlightable dot must remain a tracker-limit note.

## Repeatable diagnostic report (D8)

```sh
/usr/bin/python3 tools/diag/diag-report.py /tmp/avp-diag-logs -o /tmp/avp-report.md
/opt/homebrew/bin/python3 tools/diag/diag-report.py /tmp/avp-diag-logs \
  --sender-log /tmp/ladder.jsonl -o /tmp/avp-report.md
/usr/bin/python3 -m unittest tools/diag/test_diag_report.py
/opt/homebrew/bin/python3 -m unittest tools/diag/test_diag_report.py
```

Python 3.9+, standard library only. The input directory's `diag-*.log` files
are read in natural filename order (including rotation suffixes); stdout is the
default output. Identical inputs produce identical Markdown, with no generation
time. Every section names `filename:line` sources, retains every emitted field,
and uses **no data** for absent/nonfinite measurements. Invalid lines are skipped,
counted and listed by source; unreadable diagnostic files are reported in file
health. Unknown topics are retained there too. No app/device changes are needed.

For a UDP ladder, enable **Net sink** once (UDP, default port 9944), then run:

```sh
python3 tools/diag/netprobe-ladder.py HEADSET_IP 9944 50,100,150,200,250,300 8 90 1200 > /tmp/ladder.jsonl
```

This is the GM's `netladder.py` workflow, now using the sibling
`netprobe-send.py` wire helpers. It keeps **one UDP socket and continuous sequence
and frame IDs across all steps**. The sink pins that sender, so do not restart a
sender for each rate. Keep the entire ladder plus listener setup below the sink's
60-second limit; the example has 48 seconds of scheduled steps. Stop the sink
when the ladder finishes, pull the diagnostic logs, and pass the unedited JSONL
to `--sender-log`. TCP bulk uses a separate TCP sink run and the existing
`netprobe-send.py --mode tcp`; TCP throughput never qualifies for the UDP knee.
The ladder sender's `--help` lists its positional arguments and defaults.

The real JSONL format is one metadata record, all timed step records, then a footer:

```json
{"start_wall":1792589933.8743958,"host":"headset","port":9944,"fps":90,"packet_size":1200}
{"t_start_s":0.0,"mbps_req":100.0,"sent_mbps":100.5,"late_frames":0,"send_errors":0,"frames":90,"elapsed_s":0.994}
{"t_start_s":0.994,"mbps_req":200.0,"sent_mbps":201.5,"late_frames":0,"send_errors":0,"frames":90,"elapsed_s":0.992}
{"total_s":1.986,"packets":31320,"frames":180}
```

`t_start_s + elapsed_s` defines each step's end; elapsed time is measured, not
assumed to equal the requested hold. As in the original sender, a step ends after
sending its last scheduled frame, without an extra final frame-period wait.
`packets` in the footer counts attempted sequence numbers, including send errors;
`sent_mbps` counts bytes accepted by the socket and establishes no receipt result.
Send failures are counted per step without resetting the sequence or socket.

The report expects one UDP sink run for the ladder, with any TCP runs reported
separately. Multiple UDP runs are ambiguous and disable alignment; retain only
the intended run's logs when comparing a ladder. Listener `seconds` includes idle
time before the sender starts. The report instead aligns sink `active_seconds`
(first-to-last valid receipt) to the first sender step start. Subsequent step bounds
retain the sender's measured `t_start_s` offsets. No wall-clock alignment or
absolute one-way latency is inferred. JSON times are rounded to milliseconds;
a 2 ms comparison tolerance accounts for that rounding, not network delay/drift.

Bytes, loss, reorder, duplicates, stale/invalid/foreign packets, completed frames
and histogram overflow are cumulative. The report differences adjacent snapshots
on this receipt timeline, including the final summary; it never adds a summary to
its intervals. A final snapshot at the same rounded time replaces the earlier
one, preserving late repairs/counter updates. Each step shows only intervals
wholly contained in its bounds, their source and baseline lines, and the exact
`coverage_s`. Received Mb/s is delta bytes × 8 / covered seconds / 1e6.
`whole_step=false` means this is an interior-window measurement, not a whole-step
average. Boundary-crossing intervals are listed and never prorated or assigned to
a single rate. Missing endpoints/counters produce **no data**. Loss deltas can be
negative when late arrivals repair gaps created in an earlier step.

Jitter is run-state EWMA and p99 is a cumulative percentile; neither can be
subtracted to obtain a later step's metric. Per-step jitter is **no data**.
Completion p99 is **no data** for later steps; for a fully covered first step,
the cumulative prefix has the correct scope and can be reported. The footer has
only the total packet count, so multi-step loss percentages are **no data** too.
Raw cumulative jitter/percentiles and every sender field remain in separate tables.
These limits usually leave the continuous ladder's **knee: no data**. Additional
step-specific packet counters and distributions would be needed to measure it.

When all required measurements are available (for example a fully covered,
single-step ladder), the knee rule remains the highest requested rate with
observed loss ≤0.1% **and** completion p99 ≤1000/fps ms. Loss percent is
`100 * loss delta / matching sender packets`; trailing loss remains unknown.
A pass also requires a sender footer, final sink summary, zero send errors,
completed frames and no histogram overflow. Incomplete/malformed sender logs
cannot establish a knee. Malformed lines are skipped and counted, and disable
sender alignment so missing records never shift steps. The tests include the
actual GM sample, one continuous run with cumulative counter differences,
boundary-straddling intervals, and independent loss/deadline threshold cases.

Decode fps/Mpix/s aggregate sessions; per-session achieved fps is `fps / sessions`.
The 90/96/100 Hz flags require enough per-session throughput, zero drops,
`hw=true`, and `err=0`. Highest passing per coded size ranks source fps × sessions
among trials meeting their source cadence. These checks establish throughput,
not sustained backlog stability or unlogged latency tails. Codec hardware queries
and session checks keep separate source references. EDR threshold hold times use
the most recent matching step in that session and name that source; they are
configured holds, not a measured time between the step and mark.

Current M6 logs contain interval p50/p95/max, without interval samples/counts or
window durations. The report therefore gives the median target cadence estimate
(`1000 / target_interval_p50_ms`), and explicitly marks the histogram and achieved
Hz **no data**. Actual photon presentation remains unavailable. M9 GPU and decode
latency logs have p50/p95, not p99; p95 is preserved and never relabelled p99.
RQ sweep GPU p99 is logged and reported. M9 footprint is bytes; RQ `footprint_mb`
is MiB. Corner radii/shape/exponents/area come from the recorded summary, with
16 radii expanded in logged spoke order; missing marks are never filled in.
These reports cannot manufacture measurements the headset did not record.

## Frame capture

Enable **Diagnostics** under Advanced Settings and restart the app. Enable
**Capture diagnostic frames**, select a **Corner chart** mode, then enter the
Metal immersive space without a stream. The capture setting is read when the
renderer starts, like Corner chart. It defaults off and is hidden with Diagnostics
off. One capture is requested three seconds after the first idle frame; each
existing corner mark requests another, up to **24 per app process**. Each renderer
admits one capture at a time; intervening marks queue with their recorded eye,
spoke and percent. No captures are submitted while streaming. Restart to reset the cap.

```sh
sh tools/diag/pull-diag.sh 'DEVICE NAME OR ID' "$PWD/build/pulled-diag"
/usr/bin/python3 tools/diag/verify-capture.py build/pulled-diag/captures/UTC-N
# Depending on devicectl's destination layout, captures may be under pulled-diag/diag.
```

The puller copies the entire `Documents/diag` directory tree, including
`captures/<UTC>-<n>/capture.json` and one PNG per colour texture slice. The timeout
is five minutes for these larger pulls. Keep capture directories intact with their
logs. `DIAG capture t_ms=… dir=… slices=… bytes=… ms_encode_blit=… ms_to_write=…`
identifies each successful capture; `t_ms` is the captured submission, not the
later write's time. `ms_encode_blit` measures CPU allocation/encoding;
`ms_to_write` measures elapsed submission-to-write completion, including GPU
queueing, readback, conversion, compression and I/O. Neither isolates GPU blit time.
Failures emit `DIAG capture error=…` and consume their session slot.

Readback is a blit in the presenting command buffer, after **all** app passes and
before present. Rate tables are snapshotted while the drawable owns its map.
GPU completion schedules file work on a utility queue. The render thread never waits for readback or writes files. A capture can still add GPU copy
work and allocation cost. PNG channels are clamped to [0,1], rounded to eight bits,
with no tone curve. Saturated chart colours survive exactly; this is not lossless
storage of arbitrary HDR/half-float values. Alpha is retained, not composited.

The JSON records UTC, monotonic submission time, drawable/texture/slice/view,
physical texture size/format, logical viewport and view tangents in
**left, right, bottom, top** magnitude order. Each slice's `rate_map` contains
`screen_w + 1` physical-x samples and `screen_h + 1` physical-y samples, including
both endpoints, from Metal's `physicalCoordinates(screenCoordinates:layer:)`.
Maps are separable. Unmapped textures get identity tables. `corner_chart` is a
locked live snapshot for every capture, including the timer:
mode, eye, spoke, pct, public `ring_percents` and `cut_percents`, and all recorded
marks. The separate `trigger` object identifies the timer or corner mark that
requested it. A mark advances selection, so the live selection can differ from
the trigger. If no chart is active, its mode is Off and selection fields are null.

The independent Python 3.9+ standard-library verifier scans the **physical**
image outward on the four tangent-origin axis rays, detects cyan (L) or magenta
(R) stroke runs. D9 interior strokes are centered, so their run midpoints measure
the ring; the clipped 100% border uses its outward edge. Older captures without
`ring_stroke_alignment=center` use outward edges for their inward strokes.
It independently computes
ring positions from the recorded tangent magnitudes and percentages, interpolates
the recorded map, and inverts measured crossings into logical pixels and
normalised tangent units. Each eye/axis/ring prints expected/found physical and
logical positions and absolute physical error. Missing rings or error **>1.5
physical pixels** exit 1. Unlit monocular slices are skipped; an off chart cannot
provide ring proof. `<source-image>-logical.png` is a nearest-sample unwarped logical
preview, at most 1600 pixels wide, for visual inspection.

This proves what the app submitted, including its diagnostic overlays and raster
rate mapping. It does **not** capture lens distortion correction or reprojection,
which visionOS performs after the app's image, or prove panel output, visible
optical field, brightness, or photon timing. Mirror images are a separate path.

Validation:

```sh
/usr/bin/python3 -m unittest tools/diag/test_verify_capture.py
/opt/homebrew/bin/python3 -m unittest tools/diag/test_verify_capture.py
sh tests/swift/run-tests.sh DiagCapture
sh tests/swift/run-tests.sh DiagCaptureGPU
```

The GPU test uses the real chart geometry and Metal entry points, a two-slice
rgba16Float texture and real two-layer, nonuniform raster rate map, then the
production capture writer and Python verifier. Selection highlights can replace
eye-colour pixels on an axis: the verifier reports such an obscured ring as a failure rather than inferring its location.
The offscreen test deliberately uses no selection highlight so every ring can be
checked. A missing Metal device is a **failure**, not a pass: run this test outside the sandbox on the GM's Mac.
