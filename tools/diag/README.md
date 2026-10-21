# AVP diagnostic inputs (decision 65)

Tools only: no client changes, third-party packages, ffmpeg, downloads or device installation.
Run from the repository root on a Mac with Xcode selected and an available HEVC encoder.
The two entry scripts share `clip-engine.swift` and invoke the system Swift interpreter.

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

Port defaults to 9945; the AVP sink must already be listening. The Python file
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
