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

## Validation

```sh
/usr/bin/python3 tools/diag/test_netprobe.py
/opt/homebrew/bin/python3 tools/diag/test_netprobe.py
sh tools/diag/smoke.sh
sh -n tools/diag/pull-diag.sh
```

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
