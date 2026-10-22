#!/bin/sh
# FoV / foveation settings matrix, end to end: PC ALVR server -> visionOS simulator client.
#   sh tools/fov-matrix/run-matrix.sh --points POINTS.tsv --mode chart|rdr2 --out DIR [--dry-run]
#   sh tools/fov-matrix/run-matrix.sh --restore [--build ID]      # put the PC session back after a crashed run
# Per point: apply settings to the PC session (backed up + hashed first), restart SteamVR/dashboard, enable the angle
# chart (chart mode) or start the RDR2 hold (rdr2 mode), launch the app in the simulator with ALVR_DIAG=1, wait for the
# stream, collect a DiagFrameCapture + server dump + stats, run fov-overlay.py, then restore the session (trap: also on
# failure and Ctrl-C). Writes DIR/<point>/..., DIR/summary.tsv; stdout is the summary only (dry run: the command plan).
# Options: --build ID (ALVR build dir, default 1ce896631ea1; must be known to alvr-run2.py), --bundle-id ID,
#   --sim UDID, --stop-on-error, --overlay (force overlay in rdr2 mode), --stream-timeout S, --capture-timeout S,
#   --probe-seconds S, --settle S, --game-profile FILE.
# Env overrides: HARNESS PCPS HOLD_DIR OVERLAY PYTHON WIN FOV_OVERLAY_MODE_ARG (see README.md).
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HARNESS=${HARNESS:-/Users/noel/Projects/Management/goals/rdr2-vr/research/e4-matrix-20261021/harness}
PCPS=${PCPS:-/Users/noel/Projects/Personal/vr-gaming/tools/pcps.sh}
HOLD_DIR=${HOLD_DIR:-/Users/noel/Projects/LumenIO/Products/lumen-play-clones/gm-worker-24-gamehold}
OVERLAY=${OVERLAY:-$HERE/../diag/fov-overlay.py}
PYTHON=${PYTHON:-python3}
WIN=${WIN:-win-workstation}
FOV_OVERLAY_MODE_ARG=${FOV_OVERLAY_MODE_ARG:-}   # empty: `fov-overlay.py render ...`; set to --mode for `--mode render`
SIM=${SIM:-1227F7A6-6C9A-4A83-B8B6-3AE4BB4C902A}
BUILD=${BUILD:-1ce896631ea1}
BID=${BID:-}
PROFILE=${PROFILE:-$HOLD_DIR/local/profiles/noquad-profile.json}
PCW=${PCW:-/mnt/c/Users/noelm/claude-tmp/fov-matrix}   # override only in the stub test
TUNNEL_PORT=18082

POINTS=; MODE=; OUT=; DRY=0; RESTORE_ONLY=0; STOP_ON_ERROR=0; FORCE_OVERLAY=0
STREAM_TIMEOUT=150; CAPTURE_TIMEOUT=45; PROBE_SECONDS=30; SETTLE=

die() { echo "run-matrix: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --points) POINTS=${2:?--points needs a file}; shift 2 ;;
    --mode) MODE=${2:?--mode needs chart|rdr2}; shift 2 ;;
    --out) OUT=${2:?--out needs a directory}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --restore) RESTORE_ONLY=1; shift ;;
    --stop-on-error) STOP_ON_ERROR=1; shift ;;
    --overlay) FORCE_OVERLAY=1; shift ;;
    --build) BUILD=${2:?}; shift 2 ;;
    --bundle-id) BID=${2:?}; shift 2 ;;
    --sim) SIM=${2:?}; shift 2 ;;
    --stream-timeout) STREAM_TIMEOUT=${2:?}; shift 2 ;;
    --capture-timeout) CAPTURE_TIMEOUT=${2:?}; shift 2 ;;
    --probe-seconds) PROBE_SECONDS=${2:?}; shift 2 ;;
    --settle) SETTLE=${2:?}; shift 2 ;;
    --game-profile) PROFILE=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

FM="$PYTHON $HERE/fovmatrix.py"
if [ "$RESTORE_ONLY" = 1 ]; then
  [ -n "$OUT" ] || OUT=build/restore
else
  [ -n "$POINTS" ] && [ -f "$POINTS" ] || die "--points FILE required (got '$POINTS')"
  case $MODE in chart|rdr2) ;; *) die "--mode must be chart or rdr2" ;; esac
  [ -n "$OUT" ] || die "--out DIR required"
  $FM check "$POINTS" >/dev/null || exit 2
fi
[ -n "$SETTLE" ] || { [ "$MODE" = rdr2 ] && SETTLE=90 || SETTLE=15; }
mkdir -p "$OUT" || die "cannot create $OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
if [ -z "$BID" ]; then
  BIDFILE=/Users/noel/.claude/jobs/3ccce3d1/tmp/simint/bundle-id
  [ -f "$BIDFILE" ] && BID=$(cat "$BIDFILE")
fi
if [ -z "$BID" ]; then
  [ "$DRY" = 1 ] && BID='<bundle-id>' || die "no bundle id: pass --bundle-id (sim-int-prep.sh writes one) "
fi

# ---------------------------------------------------------------- helpers
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/run.log" >&2; }
plan() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$OUT/plan.txt"; }
x() {   # run, or print in a dry run
  if [ "$DRY" = 1 ]; then plan "+ $*"; return 0; fi
  "$@"
}
xo() {  # xo LOGFILE cmd...  : stdout+stderr to LOGFILE
  f=$1; shift
  if [ "$DRY" = 1 ]; then plan "+ $* > $f 2>&1"; return 0; fi
  "$@" > "$f" 2>&1
}

# Owner tag of this run's PC backup (pc-session.py checks it before any restore). Empty for --restore: restores whatever is there.
NONCE=; [ "$RESTORE_ONLY" = 1 ] || NONCE="$$-$(date +%s)"
TP=; PP=; APP_PID=; HOLD_REPORT=; BACKED_UP=0; STARTED=0; SESSION_SHA=; FAILED=0; DATA=
[ "$DRY" = 1 ] && : > "$OUT/plan.txt"

mk_pc() {  # mk_pc OUTFILE action args... : a POSIX sh script for `ssh WIN wsl -e sh -s` (no nested quoting)
  o=$1; shift
  {
    if [ -n "${PC_SETS:-}" ]; then
      echo "mkdir -p $PCW"; echo "cat > $PCW/sets.txt <<'SETS'"; cat "$PC_SETS"; echo 'SETS'
    fi
    echo "FOVMATRIX_NONCE=$NONCE python3 - $* <<'PY'"; cat "$HERE/pc-session.py"; echo 'PY'
  } > "$o"
}
pcrun() {  # pcrun SCRIPT LOG
  if [ "$DRY" = 1 ]; then plan "+ ssh -o ConnectTimeout=10 $WIN wsl -e sh -s < $1 > $2 2>&1"; return 0; fi
  ssh -o ConnectTimeout=10 "$WIN" wsl -e sh -s < "$1" > "$2" 2>&1
}
pc_action() {  # pc_action DIR NAME action args... ; script+log DIR/pc-NAME.{sh,log}
  d=$1; n=$2; shift 2
  mk_pc "$d/pc-$n.sh" "$@"
  pcrun "$d/pc-$n.sh" "$d/pc-$n.log"
}

fail_soft() { printf '%s\n' "$*" >> "$PD/ERROR"; log "[$NAME] PROBLEM $*"; }
fail_hard() { fail_soft "$@"; return 1; }

wait_stream() {  # until the client log shows decoded frames
  if [ "$DRY" = 1 ]; then plan "+ wait <= ${STREAM_TIMEOUT}s for ALVRSTATS frames_decoded>0 in $1"; return 0; fi
  t=0
  while [ "$t" -lt "$STREAM_TIMEOUT" ]; do
    grep -aqE 'ALVRSTATS .*"frames_decoded":[1-9]' "$1" 2>/dev/null && return 0
    sleep 3; t=$((t + 3))
  done
  return 1
}

new_capture() {  # newest capture dir not listed in file $1 whose capture.json answers our request; prints its name
  # Only trigger.reason request_file|after_ms counts: an idle start_timer/corner_mark capture (taken in a stream gap, e.g. the
  # simulator dropping the stream) is not the streaming capture and its drawable shows no stream.
  r=
  for c in "$DATA"/Documents/diag/captures/*; do
    [ -f "$c/capture.json" ] || continue
    grep -qE '"reason" *: *"(request_file|after_ms)"' "$c/capture.json" 2>/dev/null || continue
    b=$(basename "$c")
    grep -qxF "$b" "$1" 2>/dev/null || r=$b
  done
  [ -n "$r" ] && { echo "$r"; return 0; }
  return 1
}

overlay() {  # overlay MODE OUTBASE args... ; JSON must exist afterwards
  m=$1; ob=$2; shift 2
  if [ -n "$FOV_OVERLAY_MODE_ARG" ]; then set -- "$FOV_OVERLAY_MODE_ARG" "$m" "$@"; else set -- "$m" "$@"; fi
  if [ "$DRY" = 1 ]; then plan "+ $PYTHON $OVERLAY $* --out-png $ob.png --out-json $ob.json > $ob.log 2>&1"; return 0; fi
  $PYTHON "$OVERLAY" "$@" --out-png "$ob.png" --out-json "$ob.json" > "$ob.log" 2>&1
  rc=$?   # the tool may exit non-zero on FAIL verdicts; a missing JSON is the real failure
  [ -s "$ob.json" ] || { fail_soft "overlay $m: no JSON written (rc=$rc), see $ob.log"; return 1; }
  return 0
}

stop_all() {  # terminate our app, finish the hold, stop SteamVR/ALVR (as the e4 harness did)
  xo /dev/null xcrun simctl terminate "$SIM" "$BID"
  if [ -n "$HOLD_REPORT" ]; then
    if [ "$DRY" = 1 ]; then plan "+ sh $HOLD_DIR/scripts/hdr-game-run.sh finish --report <report from start.json>"; else
      sh "$HOLD_DIR/scripts/hdr-game-run.sh" finish --report "$HOLD_REPORT" > "$OUT/finish.log" 2>&1 \
        || log "WARNING: hold finish failed, see $OUT/finish.log (the game may still be running)"
    fi
    HOLD_REPORT=
  fi
  if [ "$DRY" = 1 ]; then plan "+ $PYTHON $HARNESS/alvr-run2.py stop > $OUT/stop.log 2>&1"; else
    $PYTHON "$HARNESS/alvr-run2.py" stop > "$OUT/stop.log" 2>&1 || log "note: alvr-run2 stop rc!=0 (normal when nothing was started), see $OUT/stop.log"
  fi
}

CLEANED=0
cleanup() {
  rc=$?
  # Exactly once, and uninterruptible: a second signal while restoring must not skip the restore.
  [ "$CLEANED" = 0 ] || exit "$rc"
  CLEANED=1
  trap '' INT TERM HUP
  trap - EXIT
  [ -n "$TP" ] && kill "$TP" 2>/dev/null
  [ -n "$PP" ] && kill "$PP" 2>/dev/null
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  if [ "$STARTED" = 1 ] || [ "$RESTORE_ONLY" = 1 ]; then stop_all; [ "$DRY" = 1 ] || sleep 4; fi
  if [ "$BACKED_UP" = 1 ] || [ "$RESTORE_ONLY" = 1 ]; then
    PC_SETS= pc_action "$OUT" restore restore "$BUILD"
    if [ "$DRY" = 1 ]; then :; elif grep -q '^restore OK' "$OUT/pc-restore.log" 2>/dev/null; then
      got=$(sed -n 's/^restore OK sha=//p' "$OUT/pc-restore.log" | head -1)
      if [ -n "$SESSION_SHA" ] && [ "$got" != "$SESSION_SHA" ]; then
        echo "run-matrix: SESSION HASH MISMATCH after restore: backed up $SESSION_SHA, restored $got" >&2; rc=5
      else log "PC session restored and verified ($got)"; fi
    elif grep -q '^restore SKIP FOREIGN' "$OUT/pc-restore.log" 2>/dev/null; then
      echo "run-matrix: a backup from another run is on the PC and was left untouched (not restored): $(grep '^restore SKIP FOREIGN' "$OUT/pc-restore.log" | head -1). Check $PCW, then run --restore." >&2
    elif grep -q '^restore SKIP' "$OUT/pc-restore.log" 2>/dev/null; then
      log "PC session: nothing to restore"
    else
      echo "run-matrix: PC SESSION NOT RESTORED. Output: $OUT/pc-restore.log. Backup stays at $PCW/session.orig.json on the PC; fix and rerun with --restore" >&2
      cat "$OUT/pc-restore.log" >&2 2>/dev/null; rc=5
    fi
  fi
  exit $rc
}
# Installed before any PC change (the first one is the backup below). Signals only exit; cleanup() runs from the EXIT trap.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------------------------------------------------------------- one point
run_point() {
  NAME=$1; PD=$OUT/$NAME
  mkdir -p "$PD/overlay"; rm -f "$PD/ERROR"
  log "[$NAME] start ($MODE)"
  plan_hdr="### point $NAME"; [ "$DRY" = 1 ] && plan "$plan_hdr"
  $FM sets "$POINTS" "$NAME" > "$PD/sets.txt" || { fail_hard "sets: cannot map point"; return 1; }
  CLIENT_JSON=$($FM client "$POINTS" "$NAME") || { fail_hard "client: cannot map point"; return 1; }
  OVL_ARGS=$($FM overlay-args "$POINTS" "$NAME") || { fail_hard "overlay-args: cannot map point"; return 1; }
  FOV_ARG=$(echo "$OVL_ARGS" | cut -d' ' -f1-2)
  NOSCALE_ARGS=$(echo "$OVL_ARGS" | cut -d' ' -f3-)   # --render/--foveation without --fov-scale (meta tangents already include s)

  # 1. stop everything from the last point
  stop_all; [ "$DRY" = 1 ] || sleep 6
  STARTED=1

  # 2. PC session: settings from the backup (never from the previous point), then the chart flag
  PC_SETS=$PD/sets.txt pc_action "$PD" apply apply "$PCW/sets.txt" "$BUILD"
  if [ "$DRY" != 1 ] && ! grep -q '^written' "$PD/pc-apply.log"; then
    fail_hard "pc settings: apply failed: $(tail -1 "$PD/pc-apply.log")"; return 1
  fi
  if [ "$MODE" = chart ]; then fm=dump; else fm=off; fi
  PC_SETS= pc_action "$PD" flag flag "$fm" "$BUILD"
  if [ "$DRY" != 1 ] && ! grep -q '^flag ' "$PD/pc-flag.log"; then
    fail_hard "pc flag: failed: $(tail -1 "$PD/pc-flag.log")"; return 1
  fi

  # 3. ALVR dashboard (starts SteamVR), manual client IP
  xo "$PD/dash.log" $PYTHON "$HARNESS/alvr-run2.py" dashboard "$BUILD" || { fail_hard "dashboard: alvr-run2 dashboard failed: $(tail -2 "$PD/dash.log" | tr '\n' ' ')"; return 1; }
  [ "$DRY" = 1 ] || sleep 12
  xo "$PD/manualip.log" sh "$PCPS" "$HARNESS/pc-alvr-manualip.ps1"

  # 4. client settings + launch
  if [ "$DRY" = 1 ]; then
    DATA='<app-data-container>'
    plan "+ DATA=\$(xcrun simctl get_app_container $SIM $BID data)"
    plan "+ $FM merge-client \$DATA/Documents/globalsettings.data '$CLIENT_JSON'"
    plan "+ rm -f \$DATA/Documents/diag/capture.request   # no leftover request from an earlier run"
    plan "+ ls \$DATA/Documents/diag/captures > $PD/captures.before"
  else
    DATA=$(xcrun simctl get_app_container "$SIM" "$BID" data) || { fail_hard "client: get_app_container failed (app not installed? bundle id $BID)"; return 1; }
    mkdir -p "$DATA/Documents"
    $FM merge-client "$DATA/Documents/globalsettings.data" "$CLIENT_JSON" > "$PD/client-settings.log" 2>&1 || { fail_hard "client settings: $(cat "$PD/client-settings.log")"; return 1; }
    rm -f "$DATA/Documents/diag/capture.request"   # a leftover would capture on the first stream frame, before settle
    ls "$DATA/Documents/diag/captures" > "$PD/captures.before" 2>/dev/null || : > "$PD/captures.before"
  fi
  if [ "$DRY" = 1 ]; then
    plan "+ SIMCTL_CHILD_ALVR_DIAG=1 SIMCTL_CHILD_RUST_LOG=info nohup xcrun simctl launch --console-pty --terminate-running-process $SIM $BID -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal > $PD/console.log 2>&1 &"
  else
    SIMCTL_CHILD_ALVR_DIAG=1 SIMCTL_CHILD_RUST_LOG=info nohup xcrun simctl launch --console-pty --terminate-running-process \
      "$SIM" "$BID" -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal > "$PD/console.log" 2>&1 < /dev/null &
    APP_PID=$!
  fi

  # 5. RDR2 hold
  if [ "$MODE" = rdr2 ]; then
    if [ "$DRY" = 1 ]; then plan "+ sh $HOLD_DIR/scripts/hdr-game-run.sh start --profile $PROFILE > $PD/start.json 2> $PD/start.err"; HOLD_REPORT=dry; else
      sh "$HOLD_DIR/scripts/hdr-game-run.sh" start --profile "$PROFILE" > "$PD/start.json" 2> "$PD/start.err"
      HOLD_REPORT=$($FM json-get "$PD/start.json" result.report)
      [ -n "$HOLD_REPORT" ] || { fail_hard "hold: start gave no report: $(head -c 400 "$PD/start.json") $(tail -2 "$PD/start.err")"; return 1; }
    fi
  fi

  # 6. wait for the stream, settle
  wait_stream "$PD/console.log" || { fail_hard "stream: no decoded frames in ${STREAM_TIMEOUT}s, see $PD/console.log (client connected? full immersion entered?)"; return 1; }
  log "[$NAME] stream up, settling ${SETTLE}s"
  [ "$DRY" = 1 ] && plan "+ sleep $SETTLE" || sleep "$SETTLE"

  # 7. ask the streaming client for a capture (request file; the client deletes it when it takes it), server stats
  #    probe (background) while waiting for the capture
  if [ "$DRY" = 1 ]; then plan "+ mkdir -p \$DATA/Documents/diag && echo $NAME > \$DATA/Documents/diag/capture.request"; else
    mkdir -p "$DATA/Documents/diag" && echo "$NAME" > "$DATA/Documents/diag/capture.request" || fail_soft "capture: cannot write capture.request in $DATA/Documents/diag"
  fi
  if [ "$DRY" != 1 ]; then
    ssh -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -N -L "$TUNNEL_PORT:127.0.0.1:8082" "$WIN" &
    TP=$!; sleep 3
    $PYTHON "$HARNESS/ws-probe.py" "$TUNNEL_PORT" "$PROBE_SECONDS" "$PD/events.jsonl" > "$PD/probe.log" 2>&1 &
    PP=$!
  else
    plan "+ ssh -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -N -L $TUNNEL_PORT:127.0.0.1:8082 $WIN &"
    plan "+ $PYTHON $HARNESS/ws-probe.py $TUNNEL_PORT $PROBE_SECONDS $PD/events.jsonl > $PD/probe.log 2>&1 &"
    plan "+ wait <= ${CAPTURE_TIMEOUT}s for a new DiagFrameCapture dir (trigger.reason request_file) in \$DATA/Documents/diag/captures (capture.json present)"
  fi
  CAP=
  if [ "$DRY" != 1 ]; then
    t=0
    while [ "$t" -lt "$CAPTURE_TIMEOUT" ]; do
      CAP=$(new_capture "$PD/captures.before") && break
      CAP=; sleep 3; t=$((t + 3))
    done
    wait "$PP" 2>/dev/null; PP=
    kill "$TP" 2>/dev/null; wait "$TP" 2>/dev/null; TP=
  fi
  xo "$PD/screenshot.log" xcrun simctl io "$SIM" screenshot "$PD/screenshot.png"
  [ "$DRY" = 1 ] || [ -s "$PD/events.jsonl" ] || fail_soft "probe: no server events in $PD/events.jsonl (tunnel/websocket), see $PD/probe.log"

  # 8. pull capture + app diag log
  if [ "$DRY" = 1 ]; then
    plan "+ cp -R \$DATA/Documents/diag/captures/<new> $PD/capture ; cp newest \$DATA/Documents/diag/diag-*.log $PD/"
  elif [ -n "$CAP" ]; then
    cp -R "$DATA/Documents/diag/captures/$CAP" "$PD/capture" || fail_soft "capture: copy of $CAP failed"
    latest=$(ls -t "$DATA"/Documents/diag/diag-*.log 2>/dev/null | head -1)
    [ -n "$latest" ] && cp "$latest" "$PD/"
  else
    fail_soft "capture: no streaming DiagFrameCapture (trigger.reason request_file) appeared in ${CAPTURE_TIMEOUT}s after capture.request (idle start_timer captures are ignored; see the client Diag log for the capture_trigger steps). Needs Diagnostics on (ALVR_DIAG=1 is set) and captureDiagnosticFrames (set); a client without streaming capture support ignores the request file. Screenshot kept: $PD/screenshot.png"
  fi

  # 9. server chart dump (chart mode)
  DUMP=
  if [ "$MODE" = chart ]; then
    PC_SETS= mk_pc "$PD/pc-fetch.sh" fetch-dump "$BUILD"
    if [ "$DRY" = 1 ]; then
      plan "+ ssh -o ConnectTimeout=10 $WIN wsl -e sh -s < $PD/pc-fetch.sh 2> $PD/pc-fetch.err | base64 -D | tar -xf - -C $PD   # -> $PD/dump/"
    elif ssh -o ConnectTimeout=10 "$WIN" wsl -e sh -s < "$PD/pc-fetch.sh" 2> "$PD/pc-fetch.err" | base64 -D | tar -xf - -C "$PD" 2>> "$PD/pc-fetch.err" \
         && [ -d "$PD/dump" ]; then DUMP=$PD/dump
    else
      fail_soft "dump: server chart dump not fetched: $(tail -1 "$PD/pc-fetch.err")"
    fi
  fi

  # 10. overlay tool
  if [ "$MODE" = chart ] || [ "$FORCE_OVERLAY" = 1 ]; then
    if [ "$DRY" = 1 ] || [ -d "$PD/capture" ]; then
      overlay drawable "$PD/overlay/drawable" --capture-dir "$PD/capture" $FOV_ARG
    fi
    if [ "$DRY" = 1 ]; then
      plan "+ for each PNG in $PD/dump classified by fovmatrix.py dump-files: overlay render|encoded --image <png> --eye L|R --meta $PD/dump/meta.json $NOSCALE_ARGS"
      overlay render "$PD/overlay/render-L" --image "$PD/dump/<render-L>.png" --eye L --meta "$PD/dump/meta.json" $NOSCALE_ARGS
      overlay encoded "$PD/overlay/encoded-L" --image "$PD/dump/<encoded-L>.png" --eye L --meta "$PD/dump/meta.json" $NOSCALE_ARGS
    elif [ -n "$DUMP" ]; then
      $FM dump-files "$DUMP" > "$PD/dump-files.txt"
      [ -s "$PD/dump-files.txt" ] || fail_soft "dump: no recognisable eye PNGs in $DUMP: $(ls "$DUMP" | tr '\n' ' ')"
      # the dump's meta.json holds the tangents the server really rendered (W14: device tangents misplaced every line)
      if [ -f "$DUMP/meta.json" ]; then META_ARGS="--meta $DUMP/meta.json $NOSCALE_ARGS"
      else
        META_ARGS=$OVL_ARGS
        log "[$NAME] no meta.json in the dump: render/encoded overlays use the device tangents x --fov-scale"
      fi
      while read -r dm de dn; do
        overlay "$dm" "$PD/overlay/$dm-$de" --image "$DUMP/$dn" --eye "$de" $META_ARGS
      done < "$PD/dump-files.txt"
    fi
  fi

  # 11. stats, finish
  if [ "$DRY" = 1 ]; then plan "+ $FM stats $PD/events.jsonl $PD/console.log > $PD/stats.json"; else
    $FM stats "$PD/events.jsonl" "$PD/console.log" > "$PD/stats.json" 2>/dev/null || fail_soft "stats: could not parse logs"
  fi
  if [ -n "$HOLD_REPORT" ] || [ "$DRY" = 1 ]; then stop_all; fi
  if [ -s "$PD/ERROR" ]; then log "[$NAME] done WITH PROBLEMS: $PD/ERROR"; return 1; fi
  log "[$NAME] done"
  return 0
}

# ---------------------------------------------------------------- main
if [ "$RESTORE_ONLY" = 1 ]; then log "restore only (build $BUILD)"; exit 0; fi

log "matrix $MODE: $(wc -l < "$POINTS" | tr -d ' ') lines in $POINTS, build $BUILD, out $OUT"
[ "$DRY" = 1 ] && plan "### backup PC session (hash recorded; refuses if a stale backup exists)"
# Armed BEFORE the backup runs: a signal during the backup must still restore (restore is a no-op without a backup file).
BACKED_UP=1   # restore checks the run nonce on the PC: a refused/foreign (stale) backup is never restored by this run
PC_SETS= pc_action "$OUT" backup backup "$BUILD"
if [ "$DRY" != 1 ]; then
  grep -q '^backup sha=' "$OUT/pc-backup.log" || {
    echo "run-matrix: PC session backup failed (nothing changed): $(tail -2 "$OUT/pc-backup.log")" >&2; exit 4; }
  SESSION_SHA=$(sed -n 's/^backup sha=\([0-9a-f]*\).*/\1/p' "$OUT/pc-backup.log" | head -1)
  echo "$SESSION_SHA" > "$OUT/session.sha256"
  log "PC session backed up, sha256 $SESSION_SHA"
fi

for n in $($FM names "$POINTS"); do
  run_point "$n" || { FAILED=$((FAILED + 1)); [ "$STOP_ON_ERROR" = 1 ] && { log "stopping on first error"; break; }; }
done

if [ "$DRY" = 1 ]; then
  plan "### cleanup (also runs on error / Ctrl-C): stop app + hold + SteamVR, restore PC session, verify hash"
  plan "### summary: $OUT/summary.tsv  columns: $($FM header | tr '\t' ' ')"
  exit 0
fi
{ $FM header; for n in $($FM names "$POINTS"); do $FM row "$n" "$OUT/$n"; done; } > "$OUT/summary.tsv"
cat "$OUT/summary.tsv"
[ "$FAILED" -eq 0 ] || { log "$FAILED point(s) with problems; see <point>/ERROR"; exit 1; }
exit 0
