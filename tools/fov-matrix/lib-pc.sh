# Shared PC-side functions of run-matrix.sh and run-ladder.sh (sourced, never run): the PC exec path (sh on stdin to
# `ssh WIN wsl -e sh -s`), session backup / apply / restore, the dead-server guard and the graceful SteamVR stop.
# The sourcing script sets before use: HERE HARNESS PCPS WIN PCW BUILD PYTHON OUT DRY NONCE TOOL STOP_WAIT API_WAIT
#   VRS_ARG VRLOG_ARG, and per point NAME PD. State written back: SESSION_SHA, RESTORE_RC.

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

pcps_sub() {  # pcps_sub SRC.ps1 SECONDS LOG : run a PC PowerShell script (its __SECONDS__ filled in) through pcps.sh
  s=$OUT/$(basename "$1")
  sed "s/__SECONDS__/$2/g" "$HERE/$1" > "$s"
  xo "$3" sh "$PCPS" "$s"
}

pc_backup() {  # back the PC session up once (hash recorded; refuses on a stale backup); returns 4 on failure, nothing changed
  [ "$DRY" = 1 ] && plan "### backup PC session (hash recorded; refuses if a stale backup exists)"
  PC_SETS= pc_action "$OUT" backup backup "$BUILD"
  if [ "$DRY" != 1 ]; then
    grep -q '^backup sha=' "$OUT/pc-backup.log" || {
      echo "$TOOL: PC session backup failed (nothing changed): $(tail -2 "$OUT/pc-backup.log")" >&2; return 4; }
    SESSION_SHA=$(sed -n 's/^backup sha=\([0-9a-f]*\).*/\1/p' "$OUT/pc-backup.log" | head -1)
    echo "$SESSION_SHA" > "$OUT/session.sha256"
    log "PC session backed up, sha256 $SESSION_SHA"
  fi
  return 0
}

pc_apply() {  # pc_apply SETSFILE : apply the point's session sets to the PC session (always from the backup, never from the previous point)
  PC_SETS=$1 pc_action "$PD" apply apply "$PCW/sets.txt" "$BUILD"
  if [ "$DRY" != 1 ] && ! grep -q '^written' "$PD/pc-apply.log"; then
    fail_hard "pc settings: apply failed: $(tail -1 "$PD/pc-apply.log")"; return 1
  fi
}

# Restore the PC session from this run's backup and verify the hash. RESTORE_RC=5 when it is not restored / mismatches.
restore_pc_session() {
  RESTORE_RC=0
  PC_SETS= pc_action "$OUT" restore restore "$BUILD"
  if [ "$DRY" = 1 ]; then :; elif grep -q '^restore OK' "$OUT/pc-restore.log" 2>/dev/null; then
    got=$(sed -n 's/^restore OK sha=//p' "$OUT/pc-restore.log" | head -1)
    if [ -n "${SESSION_SHA:-}" ] && [ "$got" != "$SESSION_SHA" ]; then
      echo "$TOOL: SESSION HASH MISMATCH after restore: backed up $SESSION_SHA, restored $got" >&2; RESTORE_RC=5
    else log "PC session restored and verified ($got)"; fi
  elif grep -q '^restore SKIP FOREIGN' "$OUT/pc-restore.log" 2>/dev/null; then
    echo "$TOOL: a backup from another run is on the PC and was left untouched (not restored): $(grep '^restore SKIP FOREIGN' "$OUT/pc-restore.log" | head -1). Check $PCW, then run --restore." >&2
  elif grep -q '^restore SKIP' "$OUT/pc-restore.log" 2>/dev/null; then
    log "PC session: nothing to restore"
  else
    echo "$TOOL: PC SESSION NOT RESTORED. Output: $OUT/pc-restore.log. Backup stays at $PCW/session.orig.json on the PC; fix and rerun with --restore" >&2
    cat "$OUT/pc-restore.log" >&2 2>/dev/null; RESTORE_RC=5
  fi
}

# Graceful first (ALVR dashboard shutdown request + closing the vrmonitor window), wait up to STOP_WAIT s, kill only what is left.
stop_steamvr() {
  pcps_sub pc-steamvr-stop.ps1 "$STOP_WAIT" "$OUT/steamvr-stop.log" || log "note: graceful SteamVR stop failed, see $OUT/steamvr-stop.log"
  if [ "$DRY" = 1 ]; then plan "+ $PYTHON $HARNESS/alvr-run2.py stop > $OUT/stop.log 2>&1   # kills only what the graceful stop left"; else
    $PYTHON "$HARNESS/alvr-run2.py" stop > "$OUT/stop.log" 2>&1 || log "note: alvr-run2 stop rc!=0 (normal when nothing was started), see $OUT/stop.log"
  fi
}

# Clear SteamVR's safe-mode block of the ALVR driver, start the ALVR dashboard (which starts SteamVR), then fail fast on a dead
# server (safe-mode block, dashboard API not listening) and set the manual client IP. Returns 1 after fail_hard.
start_server() {
  PC_SETS= pc_action "$PD" safemode safemode-clear $VRS_ARG
  if [ "$DRY" != 1 ]; then
    grep -q '^{"cleared"' "$PD/pc-safemode.log" || { fail_hard "safemode-clear: $(tail -1 "$PD/pc-safemode.log")"; return 1; }
    log "[$NAME] safemode-clear: $(grep '^{"cleared"' "$PD/pc-safemode.log" | head -1)"
  fi
  xo "$PD/dash.log" $PYTHON "$HARNESS/alvr-run2.py" dashboard "$BUILD" || { fail_hard "dashboard: alvr-run2 dashboard failed: $(tail -2 "$PD/dash.log" | tr '\n' ' ')"; return 1; }
  pcps_sub pc-dashboard-wait.ps1 "$API_WAIT" "$PD/api-wait.log"   # polls 127.0.0.1:8082 on the PC, <= API_WAIT s
  PC_SETS= pc_action "$PD" driver driver-check $VRLOG_ARG
  if [ "$DRY" != 1 ]; then
    if grep -q '"not_loaded": true' "$PD/pc-driver.log"; then
      fail_hard "driver blocked by safe mode: vrserver.txt says 'Not loading driver alvr_server' (SteamVR launched without the ALVR driver; see $PD/pc-driver.log)"; return 1
    fi
    grep -q '^api ok' "$PD/api-wait.log" 2>/dev/null || { fail_hard "dashboard API not listening: 127.0.0.1:8082 on the PC did not answer in ${API_WAIT}s ($(tail -1 "$PD/api-wait.log" 2>/dev/null))"; return 1; }
  fi
  xo "$PD/manualip.log" sh "$PCPS" "$HARNESS/pc-alvr-manualip.ps1"
  if [ "$DRY" != 1 ] && grep -q 'Unable to connect' "$PD/manualip.log"; then
    fail_hard "dashboard API not listening: manual-IP step: $(grep 'Unable to connect' "$PD/manualip.log" | head -1)"; return 1
  fi
  return 0
}
