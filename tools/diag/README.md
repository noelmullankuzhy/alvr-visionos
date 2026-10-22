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
10); labels are excluded from that area. `--surround NITS` fills the area
outside the grid and between labels with a PQ level (default 0, limited-range
black). For example, `--surround 203` uses the 203-nit reference white to
separate surround adaptation from the cell values. The manifest records its
source nits and luma code; filenames add `-sur203` when set. `--range coarse`
(default) gives 25
log-spaced values from 100 to 10000 nits. `--range fine` gives 25 log-spaced
values from `--lo` to `--hi` (defaults 600 and 2000 nits; require
0 < lo < hi ≤ 10000). Endpoints are included. Files are named, for example,
`grid-10-coarse-1920x1080-30.mov` or `grid-10-fine-1920x1080-30.mov`.
Use separate fresh directories for each run, including different fine bounds.

Both `grid` and `level` accept `--mastering-peak NITS` (BT.2020 primaries,
D65 white, 0.0050 cd/m² minimum luminance) and the paired `--max-cll NITS`
`--max-fall NITS`. They write ST 2086 and CEA-861.3 byte payloads through
VideoToolbox. ST 2086 chromaticity pairs use the ISO payload order G, B, R,
then D65 white; requested values and format-description readback bytes are
recorded in the manifest. Metadata adds suffixes such as
`-md1000-cll1000-fall400`.
Each supplied value must be greater than zero and at most 10000 nits; maxFALL
must not exceed maxCLL. With no metadata options, clips retain today's tagging.
The checker verifies requested extensions and byte values against the format
description. These metadata flags are limited to grid and level clips.

The continuous grid is exactly centred with cell side
`sqrt(frameWidth * frameHeight * area / 100) / 5`. Its requested area is exact.
Each shared boundary rounds to the nearest pixel, preserving seamless tiling;
raster cell widths/heights can differ by one pixel. The manifest records the
continuous geometry, actual raster bounds/area, every named cell's source nits
and limited 10-bit PQ luma code, and label bounds. Thus pixel quantisation is
explicit rather than silently claiming an exact integer-pixel area. The checker
independently reconstructs the layout and log sequence, decodes every frame to
limited P010, and checks an interior lattice in **every cell** (±3 codes), plus
the configured surround (code 64 for black), excluding labels and boundary ringing.
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
the side of the measurement area. EDR has an **Immersion: Full / Mixed** picker
(default Full); stop/exit before changing it, then reopen EDR. PQ uses mixed immersion.
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
Layout areas are fractions of each eye's drawable viewport, not calibrated
fractions of the visible optical field. Pair/grid centres follow each eye's
straight-ahead point (the projection's tangent origin), rather than the viewport
centre. Their patches are square in physical viewport pixels. The surround is
black. The original half-field **split** stays unchanged: 1.0 left, step value right.

**Video / Metal cross-path match (relative brightness, no meter):** choose
**Immersion: Full**, **Layout: match** (Compare), then **Start**. The single
head-locked Metal patch covers 5% of each eye viewport, is centred 12° left
of straight ahead using that view's tangents, and has a black surround.
Choose a single-level **level-<N>-…** PQ clip and **Play in window**. Turn so
the app's video window sits just right of the patch. Adjust until they look
equal: quick right pinch increases, quick left pinch decreases, or use **− / +**.
The value starts at 1.0 × SDR white and is shown only in the controls status
line. Steps are 0.02, or 0.10 with **Coarse**; limits are 0.1–4.0.
Press **Matched**, then select/play the next level and repeat. If equality is
outside the range, set the patch to the relevant limit and press **Video
brighter than max** or **Video darker than min**. Stop releases both paths.
Window playback beside EDR is available only for match. Clip selection and
Reload remain available while playing. Result buttons require a window item
named `level-<N>-…`; logs use the active item's immutable clip name.

```text
DIAG edr t_ms=1234 match=1 metal_value=1.500 clip=level-100-pq.mov clip_nits=100 immersion=full
DIAG edr t_ms=2345 match=above metal_value=4.000 clip=level-1000-pq.mov clip_nits=1000 immersion=full
DIAG edr t_ms=3456 match=below metal_value=0.100 clip=level-10-pq.mov clip_nits=10 immersion=full
```

Each result means **video N nominal nits == Metal V × SDR white**, or a bound.
This measures relative appearance only; it does not establish emitted nits or
calibrate either path absolutely. The window's own dimming and tone-mapping,
including effects of the full-immersion surroundings, are what is measured.
Keep window size, placement and viewing conditions consistent across levels.

**Pair comparison:** choose **pair 1%**, **pair 5%** or **pair 20%**. These percentages
are the **total** lit area: each of the two squares occupies 0.5%, 2.5% or 10% of
the eye's viewport respectively. The horizontal gap equals one patch width.
Close one eye, compare right with the fixed **1.0** reference on the left, and
answer **Right brighter**, **Same**, or **Right darker** after each change. Each
answer logs the most recently submitted step/value/layout and advances one step.
The same answer controls apply to split. Use manual mode to answer at your own pace.
For each layout and immersion, the **highest value answered “brighter”** is the
visual headroom estimate at that area; retain the complete answer sequence to
spot inconsistent responses. Compare areas under the same headset conditions.
Full immersion has shown about 1.5× in the half-field experiment; mixed has shown
no headroom. Small highlights may behave differently: these are measurements to
repeat on device, not a guarantee of a particular peak.

Pinch the ramp or tap **Next** to advance, or **Back** to revisit a step; both wrap.
**Default** steps remain 0/0.25/0.5/1/1.25/1.5/1.75/2/2.5/4.
**Fine** steps are 0.5/1/1.25/1.5/1.6/1.7/1.8/1.9/2/2.2/2.5/3/4.
Changing the step list starts at its first value. Automatic mode holds each
submitted level for 4 seconds, or 60 seconds with Sustained selected. Manual
stepping overrides the timer. Changing settings restarts that level's timer;
late frames advance once instead of skipping unpresented levels. The original
single-patch/checkerboard layouts retain the mark button.

**Graded grid:** choose **grid 1%**, **grid 10%** or **grid 50%** for a static 5×5
cluster of square cells. **Borders** defaults OFF: pitch equals cell size,
so neighbouring patches share edges exactly with no gap or overlap. Abutting
patches make small brightness differences easiest to compare without a black
line separating them. Turn Borders ON for the previous 2-physical-pixel black
seams. Total lit cell area equals the chosen fraction (seams and labels excluded). Rows **A–E** appear
on the left and columns **1–5** above, outside the grid in grey 0.15. Close one
eye and compare adjacent values along the snake: A1→A5, B5→B1, C1→C5,
D5→D1, E1→E5. The **fine** grid range has 25 values from 1.00 through 2.00
(interval 1/24 ≈ 0.04167); **coarse** runs from 0.50 through 2.90 by 0.10.
Use **knee** after locating the plateau near 1.4–1.5: its 25 values span
1.30 through 1.70 in 24 equal intervals (1/60 ≈ 0.016667), narrowing the
comparison around where brightness stops increasing. It uses the same snake
order and Mirror control.
**Mirror** reverses all 25 values to expose position bias. Record cell addresses
where differences stop being visible, then use the logged map to recover values.
All 25 cell values are logged on entry, restart, and each range/Mirror/Borders change; every grid cell line includes `borders=0|1`.
Pair/grid clusters shift inward when necessary to keep patches and grid labels
inside each eye's viewport, preserving sizes and shared edges. A `shifted=1`
line identifies the layout and eye view (0 left, 1 right), once per shifted
layout/border mode/view in each immersive renderer run.
Grids hold all values simultaneously; stepping and Automatic apply to ramp layouts.

The 520-point grouped form separates Display, Pattern, running controls and HDR
video. Immersion and ranges use segmented pickers; the Layout menu groups Ramp,
Compare and Grid patterns. Start/Stop stay together, while the running section
shows only ramp navigation/marking, comparison answers or the grid hint. Sustained
is visible only with Automatic enabled. The header reports status, immersion,
layout and the submitted value or grid range.

Every `edr` line carries `immersion=full|mixed`. `Diag.log` keeps decision 65's
timestamp-first format and quotes layout names containing spaces:

```text
DIAG edr t_ms=1234 step=9 value=4.000 layout=10% mode=auto hold_s=60 immersion=full
DIAG edr t_ms=5678 answer=brighter step=3 value=1.500 layout="pair 5%" immersion=full
DIAG edr t_ms=6789 grid="grid 10%" range=fine mirror=0 borders=0 cell=A1 value=1.000 immersion=full
DIAG pq t_ms=9000 path=window clip=pq-steps.mov current_s=2.000 step=1 rate=1.000 waiting=none
```

**PQ controls:** **Prev clip / Next clip** beside the picker wrap around and
remain enabled whenever clips exist. Changing the picker or stepping clips
while playing restarts the same playback path with the new clip (including
normal PQ playback logs). Each playback action captures the selected URL at
the press, including across immersive-space opening. **Reload** is always available. Reload and reopening
the controls keep the selection if the file still exists; the last selected
filename is saved in UserDefaults and restored across launches. A first launch
or missing remembered file falls back to the first clip.

**Play in window / Play immersive** are mutually exclusive toggles. Turning a
toggle off stops PQ playback; turning off immersive playback also dismisses
the PQ space. Switching to window playback dismisses the PQ space first.
Window playback beside EDR requires **match**; turning that window toggle off
leaves EDR running. EDR retains its separate **Start / Stop** controls.

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
   **Outline slider (about 1 min per eye; do this first).** Select **L** or **R** and
   close the other eye. A thin (0.3°) line in the eye's hue (L cyan, R orange),
   head-locked like the dots, shows one of three outline styles, inside the projection
   overlay (frustum rectangle, bbox, foveation rect: see **Projection overlay** below); a **quick right pinch on the centre cross** (no
   cursor selected) cycles **lens → rect → measured → lens**, and the status line names the active one.
   - **lens** (default): the model lens of the Frustum Pixel Map diagram
     (`BoundaryDotsLensModel.swift`; `tools/diag/lens_model.py` is the same model). Each
     edge angle of the eye's frustum (temporal T0, nasal N0, up U0, down D0; L and R
     mirror) moves in by **inset** degrees, at least 1° left: T = T0 − inset and so on,
     half-extents a_T = tan T, a_N, b_U, b_D. In that rectangle sits a per-quadrant
     superellipse: for φ around the eye axis (temporal +, up +), c = cos φ, s = sin φ,
     a = a_T if c ≥ 0 else a_N, b = b_U if s ≥ 0 else b_D, exponent n upper-nasal 2,
     upper-temporal 3, lower-nasal 1.5, lower-temporal 4, and
     ρ = 1/((|c|/a)^n + (|s|/b)^n)^(1/n); 480 points (ρc, ρs). The lens touches the
     rectangle at the four axis points, so the rectangle is its bbox. Drawn: the inset
     rectangle (thin, solid), the lens (0.3°), the two axes across the rectangle and the
     centre circle. Inset 0–30°, default 15: on the device frustum L reads temporal 45.0,
     nasal 30, up 30, down 35.0. `python3 tools/diag/lens_model.py svg` draws both eyes to
     `build/lens-model.svg`; `fixtures/lens-model.json` pins the Swift and Python models.
   - **measured** (W34's lens style): the shape of that eye's measured
     visible field, the per-ray boundary eccentricities of the 21 Oct seal-on run
     (`evidence/device-20261021/diag-20261021T152509Z.log`: the L summary's 11 rays,
     the other 13 from the Both summary; R is the mirror of L about the vertical until
     an R walk exists). The data block is `BoundaryDotsLensReference` in
     `BoundaryDots.swift` (source and date included); replace it from a later walk.
     **Caveat:** the 13 rays from the `eye=Both` walk (0, 15, 30, 60, 90, 240, 255,
     270, 285, 300, 315, 330, 345°) are binocular readings, so on the nasal side the
     left eye's own edge is probably narrower than the table says, and the R mirror
     carries the same error. A later L-only walk replaces the `left`/`right`
     dictionaries plus `tag`/`date`/`source`, and the hand values in
     `BoundaryOutlineTests` (offset 0/+5 limits, areas 0.256134/0.368449, the `rays=`
     lines) are updated with it.
     The slider moves the whole shape radially by **offset** degrees: outline point on
     ray φ = reference(φ) + offset, rays between the 24 measured ones linear in
     eccentricity; −10…+20°, default 0, positive = outward (a larger field than the
     seal-on reference). Offset 0 reads nasal 37.5, temporal 40, up 30, down 32.5.
   - **rect**: the rendered frustum edge (the latest `m5_view` tangents of this app
     session, else the device defaults L 1.7321,1,1.1918,1 / R mirrored) moved
     **inset** degrees inwards along every ray; 0–30°, default 15. Inset 0 is the
     full rendered frustum, the rendered-edge reference.
   `lens inset 15.0 deg  area ..%` (or `rect inset 15.0 deg`, `measured offset +0.0 deg`) and
   the four side limits (nasal/temporal/up/down, degrees from the head axis: the lens's
   inset rectangle sides, else read at the 0/180/90/270° rays) are shown under the centre
   cross. With no cursor selected (status shows `left drag: lens outline`, `rect outline`
   or `measured outline`), **pinch and hold with the left hand and drag right/left**:
   horizontal hand travel in the head frame changes the value, **1 cm = 1°**, right =
   outline outward in every style (lens and rect: inset down; measured: offset up),
   snapped to 0.5°, relative to the value at the grab. The lens inset per eye is what
   *Crop FOV to outline* sends on the next stream (`docs/lumen/crop-fov.md`).
   Release keeps the value; a cancelled pinch restores it; selecting a cursor mid-slide
   ends the slide at its value. Every 0.5° step of a slide logs a `dots_outline` line
   (one per step, not per frame) and the release logs the settled value once more.
   Drag until the line sits on the edge you can just see all round, then **hold the
   right pinch >= 0.5 s** (no cursor) to log it again as the deliberate mark. Each eye
   keeps its own lens inset, rect inset and offset; Both draws both eyes' overlays, each at its own
   value, but has no slider, value labels or `dots_outline` line (the outline is
   monocular). When a ray
   cursor is selected the left drag moves the cursor (step 3) instead (status shows
   `left drag: cursor`); quick right pinch the centre cross to deselect it and get the
   slider back. The dots stay as a dim 0.5° reference for per-ray checks.
3. Look at a reachable dot until the system highlights it, then quick-pinch with
   the **right hand** to select the ray and cursor dot. A **yellow 1.6° ring**
   stays on the cursor independently of gaze. Wherever you look (including empty
   black space), **pinch and hold with the left hand and drag** to move the cursor
   along its ray: hand motion along the ray's direction in the head-locked field
   (right/left for 0°/180°, up/down for 90°/270°, the projection for diagonals)
   moves it outward/inward, **1 cm per dot step**, snapping to dots as you go;
   motion across the ray and towards/away from you is ignored. Each drag is
   relative to the dot the cursor was on when the pinch began, so dragging back
   returns exactly; release leaves the cursor on the dot shown. The cursor stops
   at the ray's first dot (10°, or 20° on intermediate rays) and 70°. A cancelled drag returns the cursor to its starting dot; a quick
   left pinch without movement does nothing (reserved). The pinch point comes
   from the spatial event's `inputDevicePose`. A drag that ends on a different
   dot logs one `dots` line (`action=step_out`/`step_in`, `via=step`) at release.
4. When the cursor reaches the outermost dot you can see, **hold the right-hand
   pinch for >= 0.5 s and release**, wherever you look, to confirm it white.
   Each ray has one boundary per eye; confirming again replaces that ray's old
   boundary. Quick right-pinch a highlighted confirmed dot to clear it. Repeat
   around the 24 main rays (0° right, increasing counter-clockwise in 15° steps);
   the 24 intermediate rays (7.5°, 22.5°, …) are optional extra checks.
   The dim centre status shows eye, cursor ray/eccentricity and rays done.
   Use the centre cross between observations. The field follows your head;
   turning your head cannot bring an edge dot towards the centre. Gaze only
   needs to reach the starting dot on each ray; dragging and confirmation do
   not need an edge dot to highlight. If no starting dot on a ray can be
   highlighted, note a **tracker limit** separately and leave that ray unmarked.
   Quick right-pinch **Done** or leave with system controls to write all three
   eye summaries and return to the lobby.
5. Pull `diag-*.log` and run `diag-report.py` below. The **Boundary dots** section
   contains per-eye boundary tables, source references, and `visible_area_frac`.
   An area requires all 24 main rays and valid tangents; no missing boundary is inferred.
   Its **Outline slider** part has a table per eye: each logged style, offset or
   inset, the four limits, `area_frac` (outline polygon area in tangent space /
   frustum area), lens lines' `model`, the latest measured line's per-ray eccentricities (reference + offset) and,
   when the same logs hold confirmed dots for that eye, `max_dev_deg` plus a per-ray
   table of dot eccentricity minus outline (positive: seen outside the outline).
   The same table carries the projection columns `bbox_deg`, `fov_source`, `fov_live`,
   `fov_rect_deg`, `pxdeg_frustum`, `pxdeg_bbox` and `projection_check` (the report
   recomputes the bbox, both px/deg and the foveation rect from the logged inputs:
   `ok`, `mismatch: <fields>`, or `not logged` for lines from before the overlay),
   and a **Projection** part lists one line per Boundary dots session with the last
   logged readout per eye, e.g.
   `projection session=diag-x.log:1 eye=L source=diag-x.log:2 fov_source=a100-axis-C fov_live=no bbox_deg=41.512,37.5,31.607,32.5 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=44.108 gain=1.66 check=ok; eye=R no data`.

**Projection overlay** (Noel, 22 Oct: the projection diagram as an interactive overlay).
Drawn in the same head-frame projection as the dots, for the selected eye, or for
both in Both. Each eye's elements use its hue: **L cyan** (0, 0.79, 1), **R orange**
(1, 0.66, 0), at equal relative luminance (about 0.49); the foveation rect is
**white**. Line widths: frustum 0.4°, lens/rect/measured outline 0.3°, foveation rect 0.2°,
the lens's inset rectangle 0.15° solid with its axes 0.12°, and for rect and measured the
bbox 0.15° and dashed (short dashes, 0.02 tan drawn / 0.02 skipped, about 1.1° near the axis),
so it reads apart from the solid frustum rectangle where the two meet and on a screenshot.

| Element | What it is |
|---|---|
| Frustum rectangle | The rendered edge: the live per-eye `m5_view` tangents (device defaults until a Metal session has run). Fixed. |
| Lens shape | The outline above (lens, rect or measured style) at the eye's own slider value. Lens also draws its inset rectangle (solid; it is the bbox, no dashed box on top) and the two axes across it. |
| Eye axis | The centre cross (in the selected eye's hue; white in Both) and a 0.5°-radius circle on the axis. |
| Bounding rectangle (bbox) | Lens: the inset rectangle. Rect and measured: the axis-aligned tangent-space box of the drawn outline polygon: min/max tangent over its vertices (the 5° rays, measured and interpolated; the rect style adds its corners). It contains the lens shape, so its corners render outside the visible field; it is the **FOV to send so that every visible direction is covered**, and the smallest such box, so the render's pixels spread over less than the frustum. W37 adds the setting that sends it. |
| Foveation rect | The 1:1 centre band of ALVR's foveated encoding mapped onto the frustum: `FFR.swift:79-89` aligns centre size and shift to 2r-pixel steps, the band spans eye UV `c0 (1 + s)` to `c0 (s - 1) + 1`, `c0 = (1 - c)/2` (`Shaders.metal:152-157`), eye UV x from the temporal edge (R mirrored), y from the top. |

Foveation source: the live session's `foveated_encoding` settings and per-eye view size
when a stream is up (`fov_source=live fov_live=yes`, readout `fov (live)`); otherwise a points row compiled from
`tools/fov-matrix/points-chart-avp.tsv` at develop 6aab8e6, 22 Oct 2026 (copied in
`fixtures/projection-points.json`; `test_projection_points_table.py` checks the Swift
table against it, and against the tsv when present) (the six `fov_scale` 1 rows: `a100-asrun`,
`a100-centred`, `a100-wider`, `a100-axis-C`, `a100-axis-A`, `a100-wider-A`; default
**a100-axis-C**; `fov_live=no`, readout `fov a100-axis-C (preset, not live)`). A quick right pinch on the **fov** button (right of **Both**) cycles
the row and logs a `dots_outline` line. Boundary dots only shows with no connection
or stream, so in practice the row is what is drawn; the live branch reads
`EventHandler.shared.streamEvent` and the cached settings and does not touch the stream path.
The render size is the live view size or `round(3648 × render_scale) × round(2912 ×
render_scale)` (as `fovmatrix.py`), e.g. 4176×3333 for a100-axis-C.

Readout (three lines per eye, in the eye's hue, below **Done**):

```text
L bbox L 45.0 R 30.0 U 30.0 D 35.0 deg  tan 1.000/0.577/0.577/0.700
L fov a100-axis-C (preset, not live)  rect L 34.3 R 34.4 U 26.2 D 26.3 deg  4176x3333
L px/deg axis: frustum 26.5 → bbox 45.5 (×1.72)
```

(lens inset 15; the measured style at offset 0 reads `L bbox L 41.5 R 37.5 U 31.6 D 32.5 deg`, bbox 44.1 px/deg.)

Left/right are head-frame sides as the client reports fov tangents (L's left is
temporal, R's left nasal); degrees are `atan` of the edge tangent from the eye axis.
px/deg on the eye axis is `avp-sharpness.py`'s centre value: render px over the tan
span × π/180 (inside the 1:1 band, so no foveation squeeze), the lower of horizontal
and vertical, for the same render size spread over (a) the frustum and (b) the bbox.
One formula per language: `ProjectionOverlay.pxPerDegAxis` (Swift) and `pxdeg_axis`
in `diag-report.py`; `fixtures/projection-overlay.json` pins both (tan to 0.001,
px/deg to 0.1). Hand values (L lens inset 15, a100-axis-C): bbox tan 1.000025/0.577350/0.577350/0.700236,
bbox 45.53 px/deg (v binds). Hand values (L measured offset 0, a100-axis-C): bbox tan
0.885108/0.767327/0.615363/0.637070 (extremes on rays 195, 0, 105, 270), frustum
26.54 px/deg, bbox 44.11 px/deg. Offset +5 moves the bbox right and down edges by
exactly 5° and the left and up edges by 4.997° and 4.939°, because those extremes
lie off the axis rays. Code: `ProjectionOverlay.swift`, tested by
`tests/swift/ProjectionOverlayTests.swift`.

Geometry: 1104 dots lie at radius **10 m** on 48 rays 7.5° apart: the 24 main
rays (multiples of 15°) carry 25 dots at eccentricities 10°, 12.5°, …, 70° from
forward, the 24 intermediate rays 21 dots from 20°. Visible sphere diameter is
0.5° and collision diameter is 2.2°. Nearest centres are 2.5° apart; the inner
ring's adjacent rays are about 2.60° apart and intermediate rays start where
their neighbours are 2.56° apart. `BoundaryDotsTests` exhaustively checks all collision pairs
and checks the direction angles. At a representative 64 mm IPD, each eye is
32 mm from the head centre: its angular offset at 10 m is **0.183°**; the total
between-eye disparity is about 0.367°. Per the GM's clarification, 0.2° is the
**per-eye** target. It is well below the 2.5° radial dot spacing. Actual IPD,
device-vs-head origin, headset fit, eye cant and pose latency also limit accuracy.
The finite dot diameter, 2.5° radial quantisation, and 7.5° ray spacing limit
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
and start time until release. Left drags (cursor or outline slider) and right holds ignore the target;
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
DIAG dots_outline t_ms=104 eye=L shape=lens inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 model=superellipse(2,3,1.5,4) bbox_deg=45.001,30.000,30.000,35.001 bbox_tan=1.0000,0.5774,0.5774,0.7002 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=45.533
DIAG dots_outline t_ms=104 eye=L shape=measured offset_deg=0.000 nasal_deg=37.500 temporal_deg=40.000 up_deg=30.000 down_deg=32.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays=0:37.5,15:35,30:35,45:35,60:30,75:30,90:30,105:32.5,120:32.5,135:35,150:37.5,165:37.5,180:40,195:42.5,210:40,225:40,240:30,255:32.5,270:32.5,285:30,300:32.5,315:32.5,330:32.5,345:37.5 bbox_deg=41.512,37.500,31.607,32.500 bbox_tan=0.8851,0.7673,0.6154,0.6371 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=44.108
DIAG dots_outline t_ms=105 eye=L shape=rect inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 bbox_deg=45.001,30.489,30.489,35.058 bbox_tan=1.0000,0.5888,0.5888,0.7017 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=45.077
```

`dots_outline` (each left slider step, the slider release, and a right hold with no
cursor; L or R): `shape=lens` lines carry `inset_deg` and `model=superellipse(2,3,1.5,4)`;
their limits are the inset rectangle's sides. `shape=measured` lines carry
`offset_deg`, the `reference` tag and `rays` (the drawn eccentricity on each measured
ray, reference + offset); their limits are read from that polygon at 0/90/180/270°.
Lines from before the model lens logged the measured style as `shape=lens` with `rays`;
`diag-report.py` reads them as measured.
`shape=rect` lines carry `inset_deg`; their limits are the frustum side minus the
inset, clamped at 0. Lines without `shape` (before the lens style) are rect.
`tangent_source` is `m5_view` or `device_default`; `tangents` (left,right,bottom,top)
is the frustum used for the lens and rect outlines and for `area_frac`. Every style ends with the
projection readout: `bbox_deg`/`bbox_tan` (left,right,up,down), `fov_source` (points
row or `live`), `fov_live` (`no` for a points row, `yes` live), `foveation` (cx,cy,rx,ry,shx,shy or `off`), `fov_rect_deg`
(left,right,up,down or `off`), `render_px` (w,h), `pxdeg_frustum` and `pxdeg_bbox`.
Outline code: `BoundaryDotsLensModel` (`BoundaryDotsLensModel.swift`), `BoundaryDotsLensReference`, `BoundaryDotsFrustum`, `BoundaryDotsSlider` in `BoundaryDots.swift`,
tested by `tests/swift/BoundaryOutlineTests.swift`,
`tools/diag/test_boundary_outline_report.py` and `tools/diag/test_lens_model.py`.

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

## Resolution measurement

Measures what the Vision Pro renders and what the wearer resolves: (1) the rendered
density from each frame's rasterization rate map, in physical px per degree through
the eye axis, and whether that map follows gaze; (2) the finest square-wave grating
seen through the lens. About 5 minutes on the headset; Metal immersive space, no
stream. Code: `ALVRClient/Diagnostics/ResolutionChart.swift` (math, tested by
`tests/swift/ResolutionChartTests.swift`) and `ResolutionChartRenderer.swift`.

1. Turn on **Diagnostics** and restart the app. Under Advanced Settings set
   **Corner chart** to Off, **Resolution chart** to **Both eyes** (or Left only /
   Right only: the other eye is black), leave **Resolution chart foveation** on and
   **Render quality sweep** off. Leave the streamer disconnected.
2. **Enter diagnostics** (Metal). Keep the head still. For 20 s a white 0.5° dot
   steps centre → 20° left → 20° right → 15° up → 15° down, 4 s each: follow it
   with the eyes only. Each view logs one `rrm` line per second (20 per eye).
3. The grating chart appears, head-locked: two sets of 1.5° patches, one at the
   eye axis and one at 20° temporal. Top row vertical bars (centre 1° up), bottom
   row horizontal (centre 1.5° down); 8, 10, 12, 14, 17, 20 cycles/deg, each
   labelled. 20 cpd is the logical Nyquist on axis at quality 1.0 (40 logical
   px/deg), so finer levels cannot be drawn. The coarsest patch sits at the set's
   position and finer ones alternate outward, temporal first. Patch centres, in
   degrees temporal from the eye axis (`temporal_deg`, logged):

   | cpd | 8 | 10 | 12 | 14 | 17 | 20 |
   |---|---|---|---|---|---|---|
   | axis set | 0 | +2 | −2 | +4 | −4 | +6 |
   | temporal20 set | 20 | 22 | 18 | 24 | 16 | 26 |

   Temporal is screen left for the left eye and screen right for the right eye.
   The status under the axis set shows render quality and patch number
   (`0.50 1-24`). A yellow frame marks the current patch; the walk starts at
   render quality **0.5**.
4. Look at the framed patch. **Hold the right pinch (>= 0.5 s)** if you can see the
   bars (any orientation-correct stripes, not moiré or a grey field), **hold the
   left pinch** if not; either records and moves to the next patch. A quick right /
   left pinch moves forward / back without recording (redo a patch: the last
   judgment wins). Gamepad: d-pad right/up, left/down; A seen, B not seen.
   About 3 s per patch; 24 patches per quality.
5. After patch 24 the quality steps to **0.75**, then **1.0** (each change logs an
   `rrm` line with the new map size). After the last 1.0 patch the status reads
   `donE` and the previous render quality is restored. Leave the space.
6. Optional, foveation off: switch **Resolution chart foveation** off, leave and
   re-enter **Enter diagnostics** (the layer is configured on entry), repeat 2-5.
   `m1_config foveation=` and `grating chart=on foveation=` record what the layer
   actually got; `rrm map=none` means the drawable had no rate map. Switch the
   setting back on afterwards.
7. Pull `diag-*.log` and run `diag-report.py`; see **Resolution measurement**.

Log lines (`+` deg is screen right / up; logical coordinates are Metal's, origin
top left, y down; the eye axis is `x = tan_left/(tan_left+tan_right)·W`,
`y = tan_top/(tan_top+tan_bottom)·H` of the view's viewport):

```
DIAG rrm phase=sweep|quality s=0..19 fix=centre|left20|right20|up15|down15|none fix_x_deg fix_y_deg
         eye=L|R drawable view layer rq=<read back> fov=on|off map=ok|none screen=WxH physical=WxH
         viewport=x,y,w,h tan_left tan_right tan_bottom tan_top axis_x axis_y logical_ppd_x logical_ppd_y
         h_rate=-40:r,...,40:r h_ppd=-40:p,... v_rate=... v_ppd=... h_peak_deg v_peak_deg map_hash
DIAG grating chart=on mode=.. foveation=on|off foveation_setting=on|off
DIAG grating walk=start quality=0.500 restore=..  |  quality=0.750  |  chart=done restore=..
DIAG grating eye=both|L|R pos=axis|temporal20 cpd=8|10|12|14|17|20 orient=V|H seen=yes|no
         rq=<read back>|unavailable rq_set=<requested> fov=on|off nyquist_logical_cpd=<x.xx>|unavailable
         above_nyquist=yes|no|unknown temporal_deg up_deg size_deg=1.5
```

`*_rate` is physical px per logical px (central difference of
`physicalCoordinates(screenCoordinates:layer:)` over ±2 logical px) at 0, ±5, ±10,
±20, ±30, ±40°; `*_ppd` = rate × logical px/deg, where logical px/deg =
(W/(tan_left+tan_right))·π/180·sec²θ (40.0 on axis at quality 1.0). Angles outside
the viewport are omitted. `*_peak_deg` is the centre of the highest-rate plateau
on a 1° scan within ±40°; `map_hash` is FNV-1a of the map's parameter data, so an
unchanged hash means an unchanged map. Patch positions and sizes are true angles
(Fick: tan x = tan az, tan y = tan el / cos az) from the view tangents, not logical
pixels; bars are drawn as geometry through the rate map, so they render (and alias)
exactly as any app content would. The finest-cpd result is one wearer, one fit.

`nyquist_logical_cpd` is half the logical px/deg across the bars at the patch centre,
from the latest frame's tangents and logical viewport (both eyes: the left one).
V bars use the horizontal density k_x·sec²(az)·π/180; H bars use the vertical
density k_y·sec²(el)/cos(az)·π/180. On axis it is 15.0 / 17.5 / 20.0 at quality
0.5 / 0.75 / 1.0. A patch above it (`above_nyquist=yes`, 0.1 % slack) is still
shown and judged, but its bars alias on the render grid. The report lists those
judgments apart and never counts them as seen.

Render-grid or lens/eye limited: the report takes the physical Nyquist (half the
rate-map px/deg) from the `rrm` sample nearest in time, in the same log, with the
same eye (both: L), quality and foveation. V bars use `h_ppd` at 0° (axis), or at
−20° (L) / +20° (R) for the temporal set. H bars use `v_ppd` at 0°; for the
temporal set that is divided by cos 20°, because the rate map is separable and the
logical vertical density grows by sec(az). The verdict compares the finest level
seen with the level one step below the finest level the physical grid can carry:
- `render-grid limited`: finest seen is at or above that level, so the rendered
  pixels stop the wearer and more render resolution would show more.
- `lens/eye limited`: finest seen is below it. The grid carries finer bars that
  the optics or the eye do not pass.
- `undetermined`: no matching rate-map sample, or nothing was seen.

The report gives: a rendered px/deg profile per eye, quality and foveation (h and v
rows, one column per angle); a gaze-follow verdict per eye and sweep (`fixed`: one
map hash and peaks within 1°; `follows gaze`: peaks move ≥5° towards each
fixation; otherwise `changes, not with gaze`); and the finest seen cpd per eye
label, quality, foveation, position and orientation, with every judged level,
both Nyquists (`nyquist_logical_cpd`: lowest logged in the set;
`nyquist_physical_cpd`) and the limit verdict; then the above-Nyquist judgments
in a separate table.

Limits: selection is by stepping, not gaze, so the tested patch is the framed one;
look at it. Both eyes labels a binocular judgment. Starting a stream replaces the
chart; leaving mid-walk does not restore the quality of that (discarded) layer.
Do not run the render quality sweep at the same time (both set the quality).

### Auto capture (no judgement)

What the renderer actually draws, counted from the pixels; the manual walk above
stays for the lens/eye check.

1. **Diagnostics** on, **Corner chart** Off, **Resolution chart** = **Auto capture**
   (Render quality sweep off, streamer disconnected). **Enter diagnostics**, keep
   the headset on (or still) for about 2 minutes: the 20 s dot sweep, then for render
   quality 0.5, 0.75 and 1.0 the chart is drawn in both eyes with no frame, the
   status showing the quality. Per quality the client waits for the rate map to
   settle: the map's screen size within 1 % of the expected size for that quality
   (clamped to the layer's maximum) for 30 consecutive frames (`settle=rate_map`).
   The expected size scales the map's screen size at the entry quality by
   (0.5 + 0.5 q) / (0.5 + 0.5 q_entry), fitted on the 22 Oct device run (1.0
   6261x5023, 0.75 5479x4395, 0.5 4696x3767). The quality read-back is not used when
   there is a map: it echoes the setter at once while visionOS animates the map over
   many frames (22 Oct: the 0.5 capture was taken at 5321x4269, 34 px/deg, mid
   animation). With no map at entry the read-back confirms, as before
   (`settle=render_quality`). Then it reads back every colour texture of that drawable
   after the chart pass (the physical texture as rendered through the rate map, PNG
   per slice) into `Documents/diag/captures/chart-<UTC>-rq<q>-fov<on|off>/`, waits for
   the write and steps on. Not settled after 600 frames: captured anyway,
   `confirmed=no settle=timeout`. At the end the previous quality is restored and the
   status reads `donE`. Leave the space.
2. Foveation off: the layer's foveation is fixed when the space is configured, so
   the client cannot drop it mid-run (`fov_off=unavailable`). For the off pass set
   **Resolution chart foveation** off and enter again; that run logs `fov=off` and
   its captures are named `fovoff`.
3. Pull (`pull-diag.sh`, which copies `captures/`) and run `diag-report.py` on the
   pulled directory; it finds every `capture.json` with `chart_capture` below it.

```
DIAG chartcap step=start fov=on|off fov_off=unavailable|this_pass why=.. restore=<rq> reference_screen=WxH|none
DIAG chartcap step=quality rq_set=0.500 rq=<read back> expected_screen=WxH|none
DIAG chartcap eye=L|R rq=<read back>|unavailable rq_set confirmed=yes|no fov=on|off dir=chart-.. slice
              screen=WxH physical=WxH expected_screen=WxH|none settle=rate_map|render_quality|timeout patches=24
DIAG chartcap step=done captures=3 failed=0 fov fov_off restore=<rq>
DIAG chartcap error=capture_failed dir=..   (with DIAG capture error=..)
DIAG chartcap error=encoder_nil rq_set=..   (no render encoder that frame)
```

A failed capture (no encoder, failed write) counts in `failed=` and the walk moves
on, so it always reaches `done` and restores the entry quality. One full drawable
readback is in flight per process: while a **Capture diagnostic frames** capture
is being written the chart capture retries on the next frame, and a frame-capture
request waits (`capture_trigger step=waiting why=readback_in_flight`, kept pending)
while a chart capture is being written. The gate checks for a due request before it
takes the slot, so a chart write with no request logs no waiting line. The slot
covers the whole frame capture, sharpness-chain stages included (one submit).

`capture.json` is the frame-capture format (`slices`: eye, view, slice, png, width,
height, pixel format, `rate_map` tables) plus `trigger.reason=chartcap` and
`chart_capture`: `mode=auto`, `rq` (read back), `rq_set`, `rq_confirmed`, `fov`,
`settle_frames`, `settle`, `expected_screen`, `patch_deg`, and `views[]` with `eye, view, slice, texture_index,
tangents [l,r,b,t], viewport [x,y,w,h], screen [w,h], physical [w,h], mapped` and
`patches[]`: `position, cpd, orientation, temporal_deg, up_deg, expected_bars,
logical_rect, physical_rect` (`[x0,y0,x1,y1]`, px, origin top left, y down: the
patch's quad corners mapped through `physicalCoordinates(screenCoordinates:layer:)`
of that frame's map), `nyquist_logical_cpd` and `nyquist_physical_cpd` (logical ×
the map's rate across the bars at the patch centre). It sits next to the frame
capture's own keys (`debug_eye_tangents`, `stages`, `resample_chain`); a chart capture
has no stages.

Counting (pure Python, `count_bars` / `classify_bars`): the profile is the mean RGB
across the middle half of the physical rect, along the axis that crosses the bars
(V: x, H: y), one sample per physical pixel whose centre is inside the rect. A bar
starts where the level rises above the local mean (moving mean over two expected
periods) by 15 % of the patch's contrast and ends where it falls as far below it.
Expected count: ceil(1.5 × cpd), as drawn (12, 15, 18, 21, 26, 30).
- `correct`: count as drawn, bar and gap widths within 1 px of each other
  (rasterisation quantises edges to whole pixels; runs touching the rect edge are
  left out of the spread).
- `uneven`: count as drawn, widths spread more than 1 px.
- `missing`: count low where the bars merged to grey (over 25 % of samples between
  64 and 192), or the patch is flat (contrast under 32 levels; e.g. exactly one
  pixel per cycle: every pixel centre at the same phase).
- `aliased`: any other wrong count (full-contrast beats).

The counter assumes: white bars on black, sRGB 8-bit PNGs as written by
`DiagFrameCapture`, axis-aligned bars (the Fick tilt across a 20° temporal patch is
under half a pixel), no MSAA resolve or display blur (it reads the render target,
not the panel or the lens), and that the rate map is separable so the mapped
corners bound the rect. Decoding is the stdlib PNG reader in `verify-capture.py`
(no numpy/PIL); a 2432x2368 slice takes seconds, a 6261x5023 foveation-off slice
tens of seconds.

The report adds two tables to Resolution measurement: per capture, eye, quality,
foveation, position and orientation the finest `correct` and finest count-correct
cpd, `nyquist_logical_cpd`, `nyquist_physical_cpd` (nearest `rrm` sample of the same
eye, rq and fov, found through the `DIAG chartcap` line with that `dir`, as for the
manual walk), `nyquist_physical_capture_cpd` (the capture's own map, lowest patch
in the set), `grid_verdict` (`carries to grid Nyquist`: finest count-correct within
one level of the physical Nyquist; `below grid Nyquist`: fails earlier;
`undetermined`) and `suspect_cpd`, with each level's class; then every patch with
expected / counted bars, spreads, class and its own capture Nyquist.

`suspect`: a patch counting right above either physical Nyquist (its own capture
value or the rrm value of the set) cannot be carried by the grid, so the count is a
coincidence or the rect is wrong; it is listed and never the finest. Off-axis
Nyquist (22 Oct): the temporal20 patches are not all at 20°; each cpd sits at its own
temporal angle (8 at 20°, 10 at 22°, 12 at 18°, 14 at 24°, 17 at 16°, 20 at 26°) on
the steep foveation falloff, so each has its own physical Nyquist (V at rq 1.0: 17.1,
12.1, 19.1, 10.5, 18.7, 9.1). The capture column shows the lowest (the 26° patch), the
rrm column the 20° line value, hence 9.1 vs 17.1. The corner mapping is right: the
map is separable, the rect width over the logical width agrees with the centre rate
within the falloff across 1.5°, and the period in physical px (14 at 24°: 1.4 px;
17 at 16°: 2.2 px) explains `14:aliased, 17:correct`.

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
