# Headset bitrate / preset ladder

**What it does.** One scripted PC-side run measures six rungs on the real Vision Pro and writes one summary row per
rung. Noel only wears the headset. The script sets the PC server, launches the client on the device, probes the server for
60 s, pulls the device's own statistics and moves on to the next rung.

| Rung | Frame / band | Bitrate |
|---|---|---|
| `dC-p1-100`, `dC-p1-300`, `dC-p1-500` | crop-C (`a100-crop-C`: band centred on the eye axis) | 100 / 300 / 500 Mbps |
| `dT-p1-100`, `dT-p1-300`, `dT-p1-500` | crop-T (`a100-crop-T`: band flush with the nasal edge) | 100 / 300 / 500 Mbps |

Every rung: NVENC preset P1, multipass off, split encode ForceTwo (set explicitly: saved sessions carry Auto, which runs
one engine), HEVC 10-bit, 90 fps, the 1:1 render request (3968×3232 per eye, crop margin 2.5°). The rung file is
`tools/fov-matrix/points-device-ladder.tsv`. After the `Absolute` view-resolution sets that the points format generates,
each row sets both `video.transcoding_view_resolution` and `video.emulated_headset_view_resolution` back to the `Scale`
variant, value 1.0, so the server honours the client's 1:1 request (an `Absolute` size overrides it, see
`crop-fov.md`). The chart flag is off, so the server writes no dumps while it is timed.

## What it decides

| Configuration | Server NVENC time (measured) | Role |
|---|---|---|
| crop-C / P1 | 7.3 ms | **safe**: coded frame inside the encoder budget |
| crop-T / P1 | 9.3 ms | **stretch**: the band reaches further, coded 3200×2688 against budget C's 2784×2240 |

The ladder decides, per bitrate, whether the headset can decode each of them at 90 fps. The server numbers say whether the
PC keeps up; the device numbers say whether the headset does.

**Pass rule** (per rung, over the 60 s probe at 90 fps): `decode_ms_p95` < 11 ms **and** `dropped_total` < 1 % of the frames
received. Both are decode-side columns: `dropped_total` / `dropped_pct` count frames dropped before decode, on decode overrun
and on queue overflow only. Selection skips (older queued frames passed over for a newer one by the pacing) are reported
apart in `dropped_selection_skip` and never count against the rule. 11 ms is the 90 Hz frame budget (11.1 ms) with a little margin. A rung without device statistics is
`NO_DEVICE_STATS`, never a pass; a rung with a problem (client never connected, copy failed, ...) is `ERROR` with the
reason in `notes`.

## What Noel does

1. Put the headset on, awake, with the Vision Pro connected to the Mac (the same cable/network devicectl already uses).
2. Keep the ALVR client open and stay in the stream. Nothing else: no menus, no settings, no taking it off until the
   script prints the summary.
3. If a line starting `OPERATOR:` appears, the client did not start by itself (a launch argument the device ignored, or
   devicectl could not launch it): open ALVR in the headset and enter the stream. The script waits up to 120 s.

A rung takes about 3 minutes (server start, connect, 20 s settle, 60 s probe, stop), so the six take about 20 minutes.

## How to run it

```sh
sh tools/fov-matrix/run-ladder.sh --points tools/fov-matrix/points-device-ladder.tsv --out build/ladder-1
sh tools/fov-matrix/run-ladder.sh --dry-run --points tools/fov-matrix/points-device-ladder.tsv --out /tmp/ladder-dry   # the plan, nothing touched
sh tools/fov-matrix/run-ladder.sh --restore                       # after a crashed run: stop, restore + verify the PC session
```

Options: `--only dC-p1-300[,...]` (some rungs), `--device ID` (default Vision Pro `00008112-001E456E0C21A01E`), `--bundle-id`
(default `uk.lumenio.alvr`), `--build ID`, `--settle S` (20), `--probe-seconds S` (60), `--connect-timeout S` (120),
`--operator-after S` (20), `--stop-on-error`. Exit 0 = every rung clean, 1 = some rung had problems, 4 = PC session backup
refused (a stale backup: run `--restore`), 5 = session not restored (loud, backup kept on the PC).

Per run: back up the PC session once (hash recorded) -> per rung: stop SteamVR, apply the rung's sets from the backup,
chart flag off, `pc-session.py safemode-clear`, start the dashboard/SteamVR with the dead-server checks (dashboard API
answers, driver not blocked by safe mode), launch the client on the device -> wait up to 120 s for a StatisticsSummary with
`client_fps` > 0 -> settle 20 s -> probe the server events for 60 s -> pull the device statistics -> stop SteamVR (graceful) ->
restore the session at the end and on any error / Ctrl-C. The PC part is the code `run-matrix.sh` uses (`tools/fov-matrix/lib-pc.sh`).

The two devicectl calls (verified on the device by the dispatcher, they cannot run from a worker sandbox):

```sh
xcrun devicectl device process launch --device 00008112-001E456E0C21A01E --terminate-existing uk.lumenio.alvr \
  -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal
xcrun devicectl device copy from --device 00008112-001E456E0C21A01E --domain-type appDataContainer \
  --domain-identifier uk.lumenio.alvr --source Documents/telemetry --destination <rung dir>/telemetry
```

`devicectl help device process launch` documents the app arguments only as the trailing positional `[<command-line-arguments> ...]`
and says nothing about a `--` separator. If the device rejects `-ALVRAutoEnter` as an unknown option, run with
`LADDER_DEVICECTL_ARGSEP=--` (default empty), which inserts `--` before the arguments; the dry run prints the exact command.
The ssh tunnel is killed after each rung, when the client never connects, and on error / Ctrl-C.

The headset gets no `-ALVRDebugEyeTangents`: with Crop FOV on (the default) the client sends the same box that column
holds, from its own lens model. Check the `DIAG fov_sent ... render_1to1=3968x3232 recommended=3968x3232` line if in doubt.

## Where the numbers come from

- **Device** (the headset's own view): the client appends every per-second `ALVRSTATS` record, as JSON, to
  `Documents/telemetry/<session-start-utc>.jsonl` in the app container (`StreamTelemetryFileSink`, always on; no Diagnostics
  needed, no client change). The script copies that directory and keeps the last 60 `stats` windows of the newest session
  file that started after the rung's launch (`device-stats.jsonl`). A file from an earlier rung is never used.
  `decode_ms_mean` is the mean of the windows' `decode_ms_mean`; `decode_ms_p95` is the nearest-rank 95th percentile of the
  windows' `decode_ms_p95` (`decode_ms_p95_max` is the worst window); `dropped_total` is the sum of the decode-side drops
  (`frames_dropped` minus `dropped_selection_skip`: before decode + decode overrun + queue overflow); `dropped_pct` is that
  over the sum of `frames_received`; `dropped_selection_skip` is the sum of the pacing skips, for information; `decode_ms_p95` is a p95 of per-window p95s, not of the frames, so it leans high and `decode_ms_p95_max` bounds it;
  the last 60 windows are taken after the probe ends, so the first few seconds of that span lie just outside the server probe
  (the stream is still running while the directory is copied); `device_fps` is the mean `presented_fps`; `device_n` the number of windows (60 expected).
- **Server** (the probe, `events.jsonl`): `StatisticsSummary` events, one per second. `encode_nvenc_ms` and
  `encode_nvenc_p95` are the mean and nearest-rank p95 of `encode_nvenc_ms` over the summaries (`n/a` on a server without the
  NVENC timer); `encode_latency_ms` the mean of `encode_latency_ms`; `bitrate_mbps` the mean of `video_mbits_per_sec`.
  `encode_ms` / `encode_ms_p95` are from `GraphStatistics.encoder_s` as in the matrix (this includes composition and colour
  conversion).

Columns of `summary.tsv`: `name verdict encode_nvenc_ms encode_nvenc_p95 encode_latency_ms encode_ms encode_ms_p95
decode_ms_mean decode_ms_p95 decode_ms_p95_max dropped_total dropped_pct dropped_selection_skip device_fps bitrate_mbps device_n notes`. The matrix
`summary.tsv` gains `encode_nvenc_ms`, `encode_nvenc_p95` as its last two columns.

Files per rung in `<out>/<rung>/`: `sets.txt` (the session sets), `events.jsonl` (the probe), `telemetry/` (the copied
directory), `device-stats.jsonl` (the 60 windows used), `summary.tsv` (the row), `pc-*.sh/.log`, `launch.log`, `pull.log`,
`ERROR` (only on a problem).

## Tests

`python3 -m unittest discover -s tools/fov-matrix -t tools/fov-matrix` (NVENC columns, device statistics, ladder row and pass
rule, the points file) and `sh tools/fov-matrix/test-ladder-stubs.sh` (the live path with stub ssh / devicectl / ws-probe:
rows, stale telemetry, failing launch and copy, SIGTERM restore, no ssh tunnel left after a rung that times out or after
SIGTERM, the launch separator).
