# FoV matrix runner

One command runs a settings matrix, PC ALVR server -> visionOS simulator client, and writes a compact summary.

```sh
sh tools/fov-matrix/run-matrix.sh --points tools/fov-matrix/points-chart.tsv --mode chart --out build/m1 [--dry-run]
sh tools/fov-matrix/run-matrix.sh --restore          # after a crashed run: stop, restore + verify the PC session
```

`--dry-run` prints the full command plan (also in `<out>/plan.txt`) and writes the generated PC scripts under `<out>`; it
touches neither the PC nor the simulator. Live: progress on stderr and `<out>/run.log`; stdout is `summary.tsv` only.
Exit 0 = every point clean, 1 = some point had problems (`<out>/<point>/ERROR`), 4 = PC session backup refused
(a stale backup exists: run `--restore`), 5 = PC session NOT restored or hash mismatch (loud, backup kept on the PC).

## Points file (tab separated, `#` comments)

`name  fov_scale  render_scale  foveation  bitrate_mbps  fps  [extra path=json ...]`

- `fov_scale`: client `fovRenderScale` (globalsettings.data). `render_scale`: x 3648x2912 per eye, set as Absolute
  `transcoding_view_resolution` and `emulated_headset_view_resolution` (1.03 -> 3757x2999).
- `foveation`: `cx,cy,rx,ry,shx,shy` = center_size_x/y, edge_ratio_x/y, center_shift_x/y, or `off`.
- Extra columns: strict dotted session paths, e.g. `video.encoder_config.nvenc.split_encode_mode={"variant":"ForceTwo"}`.
- Bitrate = `video.bitrate.mode` ConstantMbps, fps = `video.preferred_fps`. Mapping lives in `fovmatrix.py` (`session_sets`).

## Per point

stop app/hold/SteamVR -> apply settings from the *backup* (never from the previous point) -> chart flag `dump` (chart mode)
or `off` (rdr2) -> `alvr-run2.py dashboard` + manual client IP -> client settings (fovRenderScale, streamFullImmersion,
captureDiagnosticFrames) -> launch with `SIMCTL_CHILD_ALVR_DIAG=1` -> (rdr2: `hdr-game-run.sh start`) -> wait for decoded
frames -> settle -> write `Documents/diag/capture.request` into the simulator app container (the streaming client takes it,
deletes it and captures the drawables it is presenting; `trigger.reason` = `request_file` in capture.json) -> server stats
probe (ws, as e4) while waiting up to 45 s (`--capture-timeout`; writing a capture took ~10 s on the simulator) for a new capture dir -> pull capture dir, screenshot, server
dump (tar over base64) -> `fov-overlay.py` drawable + render/encoded per dump PNG -> stats (encode ms/bitrate from
GraphStatistics, client fps/decode from ALVRSTATS) -> restore. The trap (installed before the first PC change, armed before the backup runs, restore exactly once) restores on error/Ctrl-C/SIGTERM/SIGHUP. Every run tags its PC backup with a nonce (`session.orig.nonce`) and only restores a backup carrying its own nonce: a stale or foreign backup is left untouched (loud message, use `--restore`). The app's `capture.request` is cleared before each launch.
capture.json colour and pose fields (streaming captures): `encoding: "srgb"` = the drawable PNGs hold sRGB-encoded values
(a linear `rgba16Float` drawable gets the sRGB transfer function on RGB, alpha stays linear; `*_srgb` formats are already
encoded and copied as is; primaries are the drawable's, untagged), so a dim chart background is visible; `source_pixel_format`
= the Metal pixel format of the drawable. `pose` = `{render, display, delta_deg, sim_yaw_dither_rad}`: `render` = the head pose
the server rendered the captured frame for (the frame's view params), `display` = the pose the drawable was presented with, each
`{yaw_deg, pitch_deg, roll_deg, t}` (`t` seconds on the layer clock); `delta_deg` = display relative to render (the display camera orientation in the render camera frame, R_render^T R_display, rotation parts only, decomposed intrinsic Y-X-Z). Convention: right-handed, yaw about +Y, pitch about +X, roll about +Z, intrinsic Y-X-Z (R = Ry*Rx*Rz), degrees.
`sim_yaw_dither_rad` = the FakeHeadPose yaw ((seq mod 1024) x 1e-5 rad) sent with that frame's pose (simulator only, else null);
idle captures have no render pose and carry no `pose` key.
Files per point: `sets.txt pc-*.sh/.log console.log events.jsonl stats.json screenshot.png capture/ dump/ overlay/ ERROR`.

`summary.tsv`: name, verdict, median_deg, max_deg, extent_err_deg, centre_px_deg (measured/predicted), fps, bitrate_mbps,
encode_ms, verdict_render, verdict_encoded, notes, encode_ms_p95, encode_over_budget. rdr2 mode skips the overlay unless `--overlay` (no chart in the image).

## Streaming capture trace

The client logs one `DIAG capture_trigger step=...` line per step in `Documents/diag/diag-*.log`: `session_started` (poll timer
running, directory polled), `request_seen` (file found and deleted), `waiting why=previous_capture_in_flight|no_stream_frame`,
`request_taken` (reason, on which frame), `submitted`, `written` (or `skipped`); the existing `capture` line adds `reason`,
`ms_gpu_done`, `ms_to_write`. The runner only accepts a capture whose `trigger.reason` is `request_file` or `after_ms`: an
idle `start_timer` capture (e.g. taken while the simulator's stream dropped) is ignored.

## Simulator bitrate

The simulator shows grey frames above about 120 Mbps, so for simulator runs use `points-chart-sim.tsv`: the same 10 points as
`points-chart.tsv` with bitrate 100 Mbps (`points-chart.tsv` keeps 500 Mbps for a real headset). `points-chain-sim.tsv` holds
three of them (f060-asrun, f070-centred, f100-asrun) for the sharpness chain (`docs/lumen/sharpness-chain.md`).

## Encoder stress

Proves the encoder holds 90 fps at 100/300/500 Mbps on real hardware (the simulator greys out above ~120 Mbps). Needs the
W20/W21 build (angle-chart `stress` flag); `--build` is its 12-char commit dir.

```sh
sh tools/fov-matrix/run-matrix.sh --points tools/fov-matrix/points-stress-enc.tsv --mode chart --out <dir> \
  --bundle-id alvr.client --build <commit12>
```

Points (`points-stress-enc.tsv`, 90 fps, foveation 0.5,0.45,3,3,0.536,-0.159, fov/render scale 1.0, NVENC P4, multi-pass
disabled): `enc-base100` (flag `dump`, split ForceTwo, 100 Mbps: normal chart as the baseline), `s100`/`s300`/`s500`
(flag `stress`, split ForceTwo, 100/300/500 Mbps), `s500-nosplit` (stress, split Disabled, 500 Mbps).

- **Chart flag, per point**: extra column `flag=dump|stress|stress,dump` (default `dump`; not a session path). The content
  is written to the same toggle file (`angle_chart.enable`) and restored with the session as before. `stress` = per-frame
  noise so the encoder runs at its bitrate cap. A flag without `dump` records statistics only: no server dump, no
  overlays (logged `skipping the server dump fetch and the overlay steps`, not a failure; the verdict column shows `NO_OVERLAY`).
- **NVENC keys** (extra columns, exact session paths from ALVR `settings.rs`): `video.encoder_config.nvenc.quality_preset={"variant":"P4"}`,
  `...nvenc.multi_pass={"variant":"Disabled"}` (or `QuarterResolution`, `FullResolution`), `...nvenc.split_encode_mode={"variant":"ForceTwo"}`
  (or `Auto`, `Disabled`). `apply` is strict: a misspelt path aborts the point.
- **Summary columns** (appended after `notes`): `encode_ms` (median), `encode_ms_p95` (nearest rank over the GraphStatistics
  `encoder_s` samples), `encode_over_budget` (fraction of those samples above the 90 Hz budget, 11.1 ms), `bitrate_mbps`
  (median achieved), `fps` (client presented fps). Holding 90 fps at 500 Mbps = `s500` with `fps` ~90, `encode_ms_p95` < 11.1,
  `encode_over_budget` ~0 and `bitrate_mbps` near 500.

## Vision Pro frustum in the simulator

`points-chart-avp.tsv` (`a100`/`a085`/`a070` x `asrun`/`centred`/`wider`, plus the doc's three recommended settings
`a100-axis-C`/`a100-axis-A`/`a100-wider-A` at their budget's render scale; 100 Mbps) makes the simulator client report
the device AVP per-eye frustum (CompositorServices |tan| L,R,D,U: L 1.7321,1,1.1918,1; R 1,1.7321,1.1918,1) x `fov_scale`
instead of its own view. Needs a client with `-ALVRDebugEyeTangents` (debug/simulator builds) and the W32 up/down fix
(`bugfix/fov-updown`): the argument fills the (left, right, bottom, top) slots, which only the fixed packing sends as
up = top.

The file is generated: the frustum, the visible field (default the 21 Oct seal-on 31/43/33/35 deg nasal/temporal/up/down)
and the foveation sizes live in `avp-field.json`; `centred` (band on the field centre) and `wider` (band spans the field)
derive from it per fov scale. After changing it (e.g. a seal-off field), regenerate (a test checks they agree):

```sh
python3 tools/diag/avp-sharpness.py points > tools/fov-matrix/points-chart-avp.tsv
python3 tools/diag/avp-sharpness.py doc > docs/lumen/avp-frustum-sharpness.md
```

- **Extra column** `eye_tangents=L:l,r,d,u;R:l,r,d,u` (not a session path): the runner appends
  `-ALVRDebugEyeTangents "<value>"` to the `simctl launch` arguments; without the column the launch is unchanged.
- The client records `debug_eye_tangents` (requested, reported, fov_render_scale) in capture.json; the drawable overlay
  places the stream by the reported tangents and fails when they are not `fov_scale` x requested. The simulator view is
  |tan| 1,1,0.5625,0.5625, so most stream edges are out of view (at 1.0 all of them: a summary note, the lines carry the check).

## Tests

```sh
/usr/bin/python3 -m unittest tools/fov-matrix/test_fovmatrix.py tools/fov-matrix/test_pc_session.py
/opt/homebrew/bin/python3 -m unittest tools/fov-matrix/test_fovmatrix.py tools/fov-matrix/test_pc_session.py
sh tools/fov-matrix/test-runner-stubs.sh      # runner with stub ssh/xcrun: happy (capture on request), failing point, SIGTERM inside the backup call, SIGTERM/SIGHUP after apply, stale backup
```

## Assumptions to check on the first live run

1. **Streaming capture needs this client change.** The client polls `capture.request` once per second (off the render
   thread) and captures the composited drawables of the next presented stream frame; one capture in flight, no GPU wait.
   Needs Diagnostics on (`ALVR_DIAG=1` is set by the runner) and `captureDiagnosticFrames` (set by the runner). Without it
   the runner records a loud `capture:` error (screenshot kept) and skips the drawable overlay. Manual alternative:
   `ALVR_DIAG_CAPTURE_AFTER_MS=N` takes one automatic capture N ms after the first presented stream frame
   (`trigger.reason` = `after_ms`; once per stream: re-armed when the stream stops).
2. `fov-overlay.py` CLI: assumed `fov-overlay.py <mode> --capture-dir|--image ... --eye --fov-scale --render --foveation
   --out-png --out-json` (positional mode; `FOV_OVERLAY_MODE_ARG=--mode` switches). Drawable runs once without `--eye` with
   `--fov-scale` only. Summary extraction reads `verdict`, `median_abs_residual_deg`, `max_abs_residual_deg`,
   `stream_extent_deg{side:{measured,predicted}}`, `implied_px_per_deg`/`predicted_px_per_deg` (band) by key search;
   missing keys show `n/a`. Overlay outputs are expected as `overlay/{drawable,render-L,...}.json`.
3. Chart dump PNG names are unspecified: classified by words (`foveated|encoder|encoded|coded` -> encoded, else render;
   `L|left|R|right` -> eye). The render/encoded overlays get `--meta <dump>/meta.json` (the tangents the server really rendered,
   already s x view, so `--fov-scale` is dropped for them; W14: device tangents misplaced every line); without a `meta.json`
   in the dump the runner logs it and falls back to the device tangents x `--fov-scale`. The drawable overlay keeps `--fov-scale`.
   Its verdict can now be `PASS-after-fitted-yaw` (capture.json has no `pose.delta_deg`) or fail with `stream extent unverified`.
4. The build in `--build` (default `1ce896631ea1`) must be in `alvr-run2.py`'s BUILDS table; the angle-chart build needs an
   entry (dir + Dashboard sha256) there. Chart mode starts no game: SteamVR is started by the ALVR dashboard.
5. Session keys follow e4 (`...Absolute.width`, `...height.content`, `foveated_encoding.enabled/content.*`,
   `bitrate.mode.ConstantMbps`); `pc-session.py apply` is strict and aborts on an unknown path.
6. Bundle id: `--bundle-id`, else `/Users/noel/.claude/jobs/3ccce3d1/tmp/simint/bundle-id` (sim-int-prep.sh). The app must be
   installed. Client IP comes from the e4 `pc-alvr-manualip.ps1` (192.168.1.14).
