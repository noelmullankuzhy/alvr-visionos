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
then a five-second horizontal gradient from 0 to 10000 nits (linear in nits).
Decision 63 steps are 0.05/0.25/0.5/1/2/4/4.926 × 203 nits, held two seconds each:
10.15, 50.75, 101.5, 203, 406, 812, 999.978 nits. Limited luma is
`round(64 + 876 * ST2084(nits/10000))`; neutral chroma is 512. Tags on the pixel
buffers and encoder are BT.2020 / SMPTE ST 2084 / BT.2020 NCL (VUI 9/16/9).
These are source luminances, not claims about panel output or headroom. No
mastering-display or content-light-level SEI metadata is synthesized.
`--seconds` truncates or extends each clip; the final step is held on extension.

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

The client's corner chart (Diagnostics on, Corner chart setting, no stream) draws
16 spokes per eye every 22.5° (0 = right, counter-clockwise), with numbered rings at
100, 95, 90, 85, 80, 75, 70, 65, 60, 55% of that eye's tangent extent along each spoke.
On the diagonals, 100 is the drawable corner. The left eye's chart is cyan and the
right's magenta (rings, numbers, spokes), with a large L / R at the eye's centre, so
each capture names the eye the mirror shows (decision 65a). Mirror the headset to the Mac (Control
Centre > Mirror My View > this Mac). The script then captures the largest on-screen
window whose owner or title matches `-w` (default `airplay`; use `-l` and pass the
owner from the list if your receiver is named differently). It captures every `-i`
seconds into `mirror-<UTC>-<n>.png`, with `index.tsv` recording the time and window id.
It exits with an error when no window matches, Screen Recording is not granted to
the terminal, or a capture fails.

To read a capture, hold the chart's head pose steady. For each spoke, the outermost
ring number visible in the image is that spoke's mirror crop. Compare it with the
`DIAG corner eye=… pos_deg=… ring_pct=…` mark you recorded on the headset (the
outermost ring you could see) and with the eye's `corner_summary` line (`r=` radii,
`axis_r`, `diag_r`, `ratio`, `shape`). The mirror is one eye's processed view, so it
shows the mirror's own crop, not the panel's visible area. A mirror crop smaller than
the marks is expected; a larger one means the marks are conservative. The summary
logs its raw numbers so the shape can be recomputed. Per quadrant with axis radii a, b
(normalised so the axis spokes are 1 at 100%), along the fixed diagonal a rectangle
is left at √2·min(a, b) and an ellipse at 1/sqrt((1/a²+1/b²)/2). Each quadrant's
superellipse exponent n solves (s/a)ⁿ + (s/b)ⁿ = 1 with s = diag_r/√2
(`superellipse_q`, inf at or beyond the rectangle); `superellipse_n` = 1/mean(1/n). An ellipse through the axis points crosses the
diagonal at ≈ 70.7%, so it marks on the 70 ring and classifies as `ellipse`
(decision 65c). A diagonal at the innermost ring (55%) sets `diag_floor=true`
(the true edge may be further in).
No visionOS 27.0 API reports the visible area (`corner api=unavailable`), so these
are subjective marks.

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
2. Choose **Boundary dots**. Keep a comfortable, steady head pose; look at a dot
   until the system highlights it, then pinch to confirm it. It turns white and
   remains confirmed. Pinch it again to clear it. Choose **L**, **R**, or **Both**
   near the fixation cross; each selection has independent marks, restored when
   switching back. These are labels only: close the other eye yourself for L/R.
   Both labels a binocular observation and is not two monocular measurements.
3. Work around all 24 rays (0° right, increasing counter-clockwise in 15° steps).
   On each ray, confirm the outermost dot you can see **and highlight**. Multiple
   confirmations on a ray are allowed; its outermost remaining mark is the boundary
   vertex. Use the small centre cross between observations; look away from it to
   select dots. The field moves with your head, so turning your head cannot bring
   an edge dot towards the centre of your view.
4. If you see a dot but cannot make it highlight, record that ray and eccentricity
   separately as a **tracker limit**, not a visibility boundary. The system does
   not report unsuccessful gaze targeting, so the app cannot infer or log this
   failure. Do not replace a visibility measurement with the last highlightable
   dot without labelling this limit in your notes. Leave affected rays unmarked
   if a boundary cannot be measured. Pinch **Done** or leave with system controls
   to write all three eye summaries; the lobby returns.
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
`HoverEffectComponent`; `SpatialTapGesture.targetedToAnyEntity()` receives the
system-selected entity. This follows Apple's documented
[device-transform placement](https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform)
and [entity gesture requirements](https://developer.apple.com/documentation/realitykit/responding-to-gestures-on-an-entity).
The [update event](https://developer.apple.com/documentation/realitykit/sceneevents/update)
runs once per frame interval. The app does not estimate gaze or read hover identity.
In Simulator, when ARKit supplies no pose, a stationary root at `(0, 1.6, 0)`
permits pointer hover/click checks. This fallback is compiled out on hardware and
does not validate head-follow latency. GM device checks must verify head locking,
hover and pinch at the centre and edge; pointer tests cannot establish tracker limits.

Each toggle writes, for example:

```text
DIAG dots_session t_ms=100 event=begin radius_m=10.000 pose=device angles=projected_tangent
DIAG dots t_ms=101 eye=L action=confirm ray_deg=45.000 ecc_deg=60.000 yaw_deg=50.768 pitch_deg=50.768
DIAG dots t_ms=102 eye=L action=clear ray_deg=45.000 ecc_deg=60.000 yaw_deg=50.768 pitch_deg=50.768
DIAG dots_summary t_ms=103 eye=L points=2 rays=0:30,90:32.5
DIAG dots_summary t_ms=103 eye=R points=0 rays=none
DIAG dots_summary t_ms=103 eye=Both points=0 rays=none
```

`points` counts all confirmed dots; `rays` is the sorted ray:outermost-eccentricity
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
