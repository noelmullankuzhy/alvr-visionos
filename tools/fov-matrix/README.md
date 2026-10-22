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
probe (ws, as e4) while waiting up to 20 s (`--capture-timeout`) for a new capture dir -> pull capture dir, screenshot, server
dump (tar over base64) -> `fov-overlay.py` drawable + render/encoded per dump PNG -> stats (encode ms/bitrate from
GraphStatistics, client fps/decode from ALVRSTATS) -> restore. The trap (installed before the first PC change, armed before the backup runs, restore exactly once) restores on error/Ctrl-C/SIGTERM/SIGHUP. Every run tags its PC backup with a nonce (`session.orig.nonce`) and only restores a backup carrying its own nonce: a stale or foreign backup is left untouched (loud message, use `--restore`). The app's `capture.request` is cleared before each launch.
Files per point: `sets.txt pc-*.sh/.log console.log events.jsonl stats.json screenshot.png capture/ dump/ overlay/ ERROR`.

`summary.tsv`: name, verdict, median_deg, max_deg, extent_err_deg, centre_px_deg (measured/predicted), fps, bitrate_mbps,
encode_ms, verdict_render, verdict_encoded, notes. rdr2 mode skips the overlay unless `--overlay` (no chart in the image).

## Simulator bitrate

The simulator shows grey frames above about 120 Mbps, so for simulator runs use `points-chart-sim.tsv`: the same 10 points as
`points-chart.tsv` with bitrate 100 Mbps (`points-chart.tsv` keeps 500 Mbps for a real headset).

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
   `L|left|R|right` -> eye). Tangents are not read from `meta.json`; the overlay defaults plus `--fov-scale` apply.
4. The build in `--build` (default `1ce896631ea1`) must be in `alvr-run2.py`'s BUILDS table; the angle-chart build needs an
   entry (dir + Dashboard sha256) there. Chart mode starts no game: SteamVR is started by the ALVR dashboard.
5. Session keys follow e4 (`...Absolute.width`, `...height.content`, `foveated_encoding.enabled/content.*`,
   `bitrate.mode.ConstantMbps`); `pc-session.py apply` is strict and aborts on an unknown path.
6. Bundle id: `--bundle-id`, else `/Users/noel/.claude/jobs/3ccce3d1/tmp/simint/bundle-id` (sim-int-prep.sh). The app must be
   installed. Client IP comes from the e4 `pc-alvr-manualip.ps1` (192.168.1.14).
