#!/bin/sh
# Headset bitrate/preset ladder, one scripted PC-side run: PC ALVR server -> the real Vision Pro. Noel only wears the headset.
#   sh tools/fov-matrix/run-ladder.sh --points tools/fov-matrix/points-device-ladder.tsv --out DIR [--dry-run]
#   sh tools/fov-matrix/run-ladder.sh --restore [--build ID]      # put the PC session back after a crashed run
# Once: back up the PC session (hash recorded). Per rung: apply the rung's sets (flag file off: no chart dumps, they would
# distort the encode time), safemode-clear + dashboard/SteamVR + the dead-server checks (lib-pc.sh, shared with run-matrix.sh),
# launch the client on the device (xcrun devicectl, -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal), wait for the client's
# StatisticsSummary (client_fps > 0) in the server events, settle, probe the server events for --probe-seconds (ws-probe.py),
# pull the device's telemetry directory (Documents/telemetry/<utc>.jsonl: the client already appends every ALVRSTATS record
# there, Diagnostics or not), keep the last N stats windows, stop SteamVR (the stream), next rung. At the end and on a trap
# (error, Ctrl-C): stop SteamVR, restore the PC session and verify the hash.
# Writes DIR/<rung>/{sets.txt,events.jsonl,device-stats.jsonl,telemetry/,summary.tsv,ERROR?}, DIR/summary.tsv; stdout is the
# summary only (dry run: the command plan, also in DIR/plan.txt).
# Pass rule (fovmatrix.py ladder_verdict): decode_ms_p95 < 11 and dropped_total < 1 % of frames received, over the probe.
# Options: --device ID (default Vision Pro 00008112-001E456E0C21A01E), --bundle-id ID (uk.lumenio.alvr), --build ID,
#   --settle S (20), --probe-seconds S (60), --connect-timeout S (120), --operator-after S (20), --only NAME[,NAME],
#   --stop-on-error. A launch argument the device ignores: after --operator-after s without a client the script prints one
#   "OPERATOR:" line asking for a manual start and keeps waiting up to --connect-timeout.
# Env overrides: HARNESS PCPS PYTHON WIN PCW XCRUN VRSETTINGS VRSERVER_LOG (see README.md), LADDER_DEVICECTL_ARGSEP (default
#   empty; `--` puts a separator before the client's -ALVR... arguments in the devicectl launch, if the device rejects them).
# The ssh tunnel is killed after every rung, at the client-connect timeout, and on EXIT/INT/TERM/HUP (cleanup).
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HARNESS=${HARNESS:-/Users/noel/Projects/Management/goals/rdr2-vr/research/e4-matrix-20261021/harness}
PCPS=${PCPS:-/Users/noel/Projects/Personal/vr-gaming/tools/pcps.sh}
PYTHON=${PYTHON:-python3}
WIN=${WIN:-win-workstation}
XCRUN=${XCRUN:-xcrun}
DEVICE=${DEVICE:-00008112-001E456E0C21A01E}
BID=${BID:-uk.lumenio.alvr}
ARGSEP=${LADDER_DEVICECTL_ARGSEP:-}   # unquoted where used: empty vanishes, `--` becomes one word
BUILD=${BUILD:-1ce896631ea1}
PCW=${PCW:-/mnt/c/Users/noelm/claude-tmp/fov-matrix}   # override only in the stub test
TOOL=run-ladder
TUNNEL_PORT=18082
API_WAIT=20    # s the dashboard API (127.0.0.1:8082 on the PC) gets to answer after SteamVR launched
STOP_WAIT=10   # s SteamVR gets to quit gracefully before the leftovers are killed
CONNECT_SLICE=5   # s of one server-events read while waiting for the client
VRS_ARG=${VRSETTINGS:+--file $VRSETTINGS}
VRLOG_ARG=${VRSERVER_LOG:+--file $VRSERVER_LOG}

POINTS=; OUT=; DRY=0; RESTORE_ONLY=0; STOP_ON_ERROR=0; ONLY=
SETTLE=20; PROBE_SECONDS=60; CONNECT_TIMEOUT=120; OPERATOR_AFTER=20

die() { echo "run-ladder: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --points) POINTS=${2:?--points needs a file}; shift 2 ;;
    --out) OUT=${2:?--out needs a directory}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --restore) RESTORE_ONLY=1; shift ;;
    --stop-on-error) STOP_ON_ERROR=1; shift ;;
    --only) ONLY=${2:?--only needs NAME[,NAME]}; shift 2 ;;
    --device) DEVICE=${2:?}; shift 2 ;;
    --bundle-id) BID=${2:?}; shift 2 ;;
    --build) BUILD=${2:?}; shift 2 ;;
    --settle) SETTLE=${2:?}; shift 2 ;;
    --probe-seconds) PROBE_SECONDS=${2:?}; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT=${2:?}; shift 2 ;;
    --operator-after) OPERATOR_AFTER=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

FM="$PYTHON $HERE/fovmatrix.py"
if [ "$RESTORE_ONLY" = 1 ]; then
  [ -n "$OUT" ] || OUT=build/ladder-restore
else
  [ -n "$POINTS" ] && [ -f "$POINTS" ] || die "--points FILE required (got '$POINTS')"
  [ -n "$OUT" ] || die "--out DIR required"
  $FM check "$POINTS" >/dev/null || exit 2
fi
mkdir -p "$OUT" || die "cannot create $OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

# Owner tag of this run's PC backup (pc-session.py checks it before any restore). Empty for --restore: restores whatever is there.
NONCE=; [ "$RESTORE_ONLY" = 1 ] || NONCE="$$-$(date +%s)"
TP=; PP=; BACKED_UP=0; STARTED=0; SESSION_SHA=; FAILED=0; RESTORE_RC=0; NAME=; PD=$OUT
[ "$DRY" = 1 ] && : > "$OUT/plan.txt"
. "$HERE/lib-pc.sh"   # log plan x xo, the PC exec path, backup/apply/restore, start_server, stop_steamvr (shared with run-matrix.sh)

kill_tunnel() {  # the ssh tunnel of the current rung; safe to call with none running
  if [ -n "$TP" ]; then kill "$TP" 2>/dev/null; wait "$TP" 2>/dev/null; TP=; fi
}

CLEANED=0
cleanup() {
  rc=$?
  # Exactly once, and uninterruptible: a second signal while restoring must not skip the restore.
  [ "$CLEANED" = 0 ] || exit "$rc"
  CLEANED=1
  trap '' INT TERM HUP
  trap - EXIT
  kill_tunnel
  [ -n "$PP" ] && kill "$PP" 2>/dev/null
  if [ "$STARTED" = 1 ] || [ "$RESTORE_ONLY" = 1 ]; then stop_steamvr; [ "$DRY" = 1 ] || sleep 4; fi
  if [ "$BACKED_UP" = 1 ] || [ "$RESTORE_ONLY" = 1 ]; then
    restore_pc_session; [ "$RESTORE_RC" = 0 ] || rc=$RESTORE_RC
  fi
  exit $rc
}
# Installed before any PC change (the first one is the backup below). Signals only exit; cleanup() runs from the EXIT trap.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_client() {  # until the server events show the client streaming (StatisticsSummary client_fps > 0)
  if [ "$DRY" = 1 ]; then
    plan "+ every ${CONNECT_SLICE}s up to ${CONNECT_TIMEOUT}s: $PYTHON $HARNESS/ws-probe.py $TUNNEL_PORT $CONNECT_SLICE $PD/connect.jsonl; $FM client-connected $PD/connect.jsonl"
    plan "+ after ${OPERATOR_AFTER}s without a client print: OPERATOR: the client did not start by itself; open ALVR in the headset and enter the stream"
    return 0
  fi
  t=0; told=0
  while [ "$t" -lt "$CONNECT_TIMEOUT" ]; do
    $PYTHON "$HARNESS/ws-probe.py" "$TUNNEL_PORT" "$CONNECT_SLICE" "$PD/connect.jsonl" > "$PD/connect-probe.log" 2>&1
    $FM client-connected "$PD/connect.jsonl" && return 0
    t=$((t + CONNECT_SLICE))
    if [ "$told" = 0 ] && [ "$t" -ge "$OPERATOR_AFTER" ]; then
      told=1; echo "OPERATOR: the client did not start by itself; open ALVR in the headset and enter the stream" >&2
    fi
  done
  return 1
}

# ---------------------------------------------------------------- one rung
run_rung() {
  NAME=$1; PD=$OUT/$NAME
  mkdir -p "$PD"; rm -f "$PD/ERROR"
  kill_tunnel   # none should be left from the last rung; never two
  log "[$NAME] start"
  [ "$DRY" = 1 ] && plan "### rung $NAME"
  $FM sets "$POINTS" "$NAME" > "$PD/sets.txt" || { fail_hard "sets: cannot map rung"; return 1; }

  # 1. stop everything from the last rung
  stop_steamvr; [ "$DRY" = 1 ] || sleep 6
  STARTED=1

  # 2. PC session: the rung's sets from the backup (never from the previous rung), chart flag off
  pc_apply "$PD/sets.txt" || return 1
  PC_SETS= pc_action "$PD" flag flag off "$BUILD"
  if [ "$DRY" != 1 ] && ! grep -q '^flag ' "$PD/pc-flag.log"; then
    fail_hard "pc flag: failed: $(tail -1 "$PD/pc-flag.log")"; return 1
  fi

  # 3. safemode-clear, dashboard/SteamVR, dead-server checks, manual client IP
  start_server || return 1

  # 4. server events tunnel, then the client on the device (the telemetry file of this session starts after SINCE)
  if [ "$DRY" = 1 ]; then
    plan "+ ssh -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -N -L $TUNNEL_PORT:127.0.0.1:8082 $WIN &"
    SINCE='<utc-now-10s>'
  else
    ssh -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -N -L "$TUNNEL_PORT:127.0.0.1:8082" "$WIN" &
    TP=$!; sleep 3
    SINCE=$(date -u -v-10S +%Y%m%dT%H%M%SZ)
  fi
  # No -ALVRDebugEyeTangents: the device sends its own crop box (Crop FOV on = the box in the points file's eye_tangents column).
  if [ "$DRY" = 1 ]; then
    plan "+ $XCRUN devicectl device process launch --device $DEVICE --terminate-existing $BID${ARGSEP:+ $ARGSEP} -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal > $PD/launch.log 2>&1"
  elif ! "$XCRUN" devicectl device process launch --device "$DEVICE" --terminate-existing "$BID" $ARGSEP -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal > "$PD/launch.log" 2>&1; then
    log "[$NAME] devicectl launch failed, see $PD/launch.log: $(tail -1 "$PD/launch.log")"
    echo "OPERATOR: devicectl could not launch the client ($(tail -1 "$PD/launch.log")); open ALVR in the headset and enter the stream" >&2
  fi

  # 5. wait for the client, settle, probe
  wait_client || { kill_tunnel; fail_hard "client: no client_fps > 0 in the server events in ${CONNECT_TIMEOUT}s (headset on? client open? see $PD/launch.log, $PD/connect-probe.log)"; return 1; }
  log "[$NAME] client streaming, settling ${SETTLE}s"
  [ "$DRY" = 1 ] && plan "+ sleep $SETTLE" || sleep "$SETTLE"
  if [ "$DRY" = 1 ]; then
    plan "+ $PYTHON $HARNESS/ws-probe.py $TUNNEL_PORT $PROBE_SECONDS $PD/events.jsonl > $PD/probe.log 2>&1"
  else
    $PYTHON "$HARNESS/ws-probe.py" "$TUNNEL_PORT" "$PROBE_SECONDS" "$PD/events.jsonl" > "$PD/probe.log" 2>&1
    [ -s "$PD/events.jsonl" ] || fail_soft "probe: no server events in $PD/events.jsonl (tunnel/websocket), see $PD/probe.log"
  fi

  # 6. device statistics: the telemetry directory of the app container, the last PROBE_SECONDS windows of the newest session
  if [ "$DRY" = 1 ]; then
    plan "+ mkdir -p $PD/telemetry"
    plan "+ $XCRUN devicectl device copy from --device $DEVICE --domain-type appDataContainer --domain-identifier $BID --source Documents/telemetry --destination $PD/telemetry > $PD/pull.log 2>&1"
    plan "+ $FM device-select $PD/telemetry $PROBE_SECONDS $SINCE > $PD/device-stats.jsonl   # last ${PROBE_SECONDS} stats windows of the newest session file at or after $SINCE"
  else
    rm -rf "$PD/telemetry"; mkdir -p "$PD/telemetry"
    if "$XCRUN" devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BID" \
         --source Documents/telemetry --destination "$PD/telemetry" > "$PD/pull.log" 2>&1; then
      $FM device-select "$PD/telemetry" "$PROBE_SECONDS" "$SINCE" > "$PD/device-stats.jsonl" 2>> "$PD/pull.log"
      [ -s "$PD/device-stats.jsonl" ] || fail_soft "device stats: no stats windows in a telemetry file at or after $SINCE under $PD/telemetry (see $PD/pull.log)"
    else
      fail_soft "device stats: devicectl copy of Documents/telemetry failed: $(tail -1 "$PD/pull.log")"
    fi
  fi

  # 7. stop the stream (tunnel, then SteamVR gracefully), the rung's row
  if [ "$DRY" = 1 ]; then plan "+ kill <tunnel>"; else kill_tunnel; fi
  stop_steamvr
  if [ "$DRY" = 1 ]; then plan "+ $FM ladder-row $NAME $PD > $PD/summary.tsv"; else
    { $FM ladder-header; $FM ladder-row "$NAME" "$PD"; } > "$PD/summary.tsv"
  fi
  if [ -s "$PD/ERROR" ]; then log "[$NAME] done WITH PROBLEMS: $PD/ERROR"; return 1; fi
  log "[$NAME] done"
  return 0
}

# ---------------------------------------------------------------- main
if [ "$RESTORE_ONLY" = 1 ]; then log "restore only (build $BUILD)"; exit 0; fi

NAMES=$($FM names "$POINTS")
if [ -n "$ONLY" ]; then
  keep=
  for n in $NAMES; do
    case ",$ONLY," in *",$n,"*) keep="$keep $n" ;; esac
  done
  [ -n "$keep" ] || die "--only $ONLY matches no rung in $POINTS"
  NAMES=$keep
fi
log "ladder: $(echo $NAMES | wc -w | tr -d ' ') rung(s) of $POINTS, build $BUILD, device $DEVICE ($BID), out $OUT"
# Armed BEFORE the backup runs: a signal during the backup must still restore (restore is a no-op without a backup file).
BACKED_UP=1   # restore checks the run nonce on the PC: a refused/foreign (stale) backup is never restored by this run
pc_backup || exit 4

for n in $NAMES; do
  run_rung "$n" || { FAILED=$((FAILED + 1)); [ "$STOP_ON_ERROR" = 1 ] && { log "stopping on first error"; break; }; }
done

if [ "$DRY" = 1 ]; then
  plan "### cleanup (also runs on error / Ctrl-C): stop SteamVR, restore PC session, verify hash"
  plan "### summary: $OUT/summary.tsv  columns: $($FM ladder-header | tr '\t' ' ')"
  exit 0
fi
{ $FM ladder-header; for n in $NAMES; do $FM ladder-row "$n" "$OUT/$n"; done; } > "$OUT/summary.tsv"
cat "$OUT/summary.tsv"
[ "$FAILED" -eq 0 ] || { log "$FAILED rung(s) with problems; see <rung>/ERROR"; exit 1; }
exit 0
