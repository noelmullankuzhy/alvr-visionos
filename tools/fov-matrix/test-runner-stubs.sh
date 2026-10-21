#!/bin/sh
# Runner test with stub ssh/xcrun/harness/overlay (no PC, no simulator): happy path, a point that fails (bad settings
# path), and SIGTERM mid-run. In every case the fake PC session must be restored byte for byte.
#   sh tools/fov-matrix/test-runner-stubs.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fovmatrix-stub.XXXXXX") || exit 2
if [ "${1:-}" = --keep ]; then echo "keeping $T"; else trap 'rm -rf "$T"' EXIT; fi
FAILS=0
check() { if [ "$1" = ok ]; then echo "ok   $2"; else echo "FAIL $2"; FAILS=$((FAILS + 1)); fi; }
t() { if eval "$1"; then check ok "$2"; else check no "$2"; fi; }

mkdir -p "$T/bin" "$T/harness" "$T/pc/alvr-build/out/b1/alvr_streamer_windows" "$T/data/Documents"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = -N ] && exec /bin/sleep 600; done
s=$FAKE_PC/.ssh-script.$$; cat > "$s"
FOVMATRIX_PC_ROOT=$FAKE_PC sh "$s"; rc=$?
# Test hook: hold the runner inside the backup call (backup file written, runner not yet back) so a signal lands there.
if [ -n "${HOLD_AFTER_BACKUP:-}" ] && grep -q '^python3 - backup' "$s"; then : > "$HOLD_AFTER_BACKUP"; /bin/sleep 3; fi
rm -f "$s"; exit $rc
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
exec /bin/sleep 0.2
EOF
cat > "$T/bin/xcrun" <<'EOF'
#!/bin/sh
case "$2" in
  get_app_container) echo "$FAKE_DATA" ;;
  launch)
    [ -n "${NOSTREAM:-}" ] || echo 'ALVRSTATS {"frames_decoded":5,"presented_fps":89.5,"decode_ms_mean":7.0}'
    d="$FAKE_PC/angle-chart/s-$$"; mkdir -p "$d"; : > "$d/chart_L.png"; : > "$d/encoder_input_L.png"; echo '{}' > "$d/meta.json"
    # The streaming client takes a capture only on request: the runner writes Documents/diag/capture.request, the client deletes it.
    ( n=0; while [ ! -f "$FAKE_DATA/Documents/diag/capture.request" ] && [ $n -lt 300 ]; do /bin/sleep 0.2; n=$((n + 1)); done
      [ -f "$FAKE_DATA/Documents/diag/capture.request" ] || exit 0
      rm -f "$FAKE_DATA/Documents/diag/capture.request"; mkdir -p "$FAKE_DATA/Documents/diag/captures/S-$$"
      echo '{"trigger":{"reason":"request_file"}}' > "$FAKE_DATA/Documents/diag/captures/S-$$/capture.json" ) &
    exec /bin/sleep 600 ;;
  io) for a in "$@"; do last=$a; done; : > "$last" ;;
esac
exit 0
EOF
cat > "$T/harness/alvr-run2.py" <<'EOF'
import sys
EOF
cat > "$T/harness/ws-probe.py" <<'EOF'
import json, sys
open(sys.argv[3], 'w').write(json.dumps({'event_type': {'id': 'GraphStatistics', 'data': {'encoder_s': 0.009, 'bitrate_bps': 5e8, 'client_fps': 90.0}}}) + '\n')
EOF
: > "$T/harness/pc-alvr-manualip.ps1"
echo : > "$T/pcps.sh"
cat > "$T/overlay.py" <<'EOF'
import json, sys
a = sys.argv[1:]
out = a[a.index('--out-json') + 1]
json.dump({'summary': {'verdict': 'PASS', 'median_abs_residual_deg': 0.02, 'max_abs_residual_deg': 0.2}}, open(out, 'w'))
open(a[a.index('--out-png') + 1], 'w').close()
EOF
chmod +x "$T/bin/"*

cat > "$T/mk.py" <<'EOF'
import json, sys
json.dump({'session_settings': {'video': {
    'preferred_fps': 72.0, 'bitrate': {'mode': {'variant': 'Adaptive', 'ConstantMbps': 30}},
    'foveated_encoding': {'enabled': True, 'content': {'center_size_x': 0.4, 'center_size_y': 0.4, 'edge_ratio_x': 4.0,
                                                       'edge_ratio_y': 4.0, 'center_shift_x': 0.0, 'center_shift_y': 0.0}},
    'transcoding_view_resolution': {'variant': 'Scale', 'Scale': 1.0, 'Absolute': {'width': 1, 'height': {'enabled': True, 'content': 1}}},
    'emulated_headset_view_resolution': {'variant': 'Scale', 'Scale': 1.0, 'Absolute': {'width': 1, 'height': {'enabled': True, 'content': 1}}},
}}}, open(sys.argv[1], 'w'), indent=2)
EOF
SESSION=$T/pc/alvr-build/out/b1/alvr_streamer_windows/session.json
python3 "$T/mk.py" "$SESSION"
cp "$SESSION" "$T/session.orig"

printf 'p1\t1.0\t1.0\t0.5,0.45,3,3,0,0\t500\t90\np2\t0.7\t1.03\toff\t500\t90\n' > "$T/ok.tsv"
printf 'p1\t1.0\t1.0\t0.5,0.45,3,3,0,0\t500\t90\nbad\t0.7\t1.0\toff\t500\t90\tvideo.nope.x=1\np3\t0.6\t1.0\toff\t500\t90\n' > "$T/bad.tsv"

run() {  # run TSV OUTDIR [extra args]
  tsv=$1; od=$2; shift 2
  PATH="$T/bin:$PATH" PCW="$T/pc/fov-matrix" FAKE_PC="$T/pc" FAKE_DATA="$T/data" HARNESS="$T/harness" PCPS="$T/pcps.sh" OVERLAY="$T/overlay.py" \
    ${EXEC:-} sh "$HERE/run-matrix.sh" --points "$tsv" --mode chart --out "$od" --build b1 --bundle-id x.y --capture-timeout 20 \
    --stream-timeout 20 --probe-seconds 1 --settle 1 "$@"
}

echo "== happy path"
run "$T/ok.tsv" "$T/o1" > "$T/o1.out" 2> "$T/o1.err"; rc=$?
t "[ $rc = 0 ]" "exit 0 (rc=$rc)"
t "[ \$(wc -l < $T/o1.out) = 3 ]" "stdout is the summary only (header + 2 rows)"
t "grep -q '^p1	PASS	0.020	0.200' $T/o1.out" "p1 row PASS with residuals"
t "grep -q '89.5	500.0	9.00' $T/o1.out" "fps / bitrate / encode ms from the logs"
t "cmp -s $SESSION $T/session.orig" "session restored byte for byte"
t "[ -f $T/o1/p1/overlay/render-L.json ] && [ -f $T/o1/p1/overlay/encoded-L.json ] && [ -f $T/o1/p1/overlay/drawable.json ]" "drawable + render + encoded overlays ran"
t "grep -q 'restored and verified' $T/o1/run.log" "restore verified in the log"
t "grep -q request_file $T/o1/p1/capture/capture.json" "capture was taken on request (capture.json trigger request_file) and pulled"
t "! [ -e $T/data/Documents/diag/capture.request ]" "request file consumed by the (stub) client"

echo "== failing point"
run "$T/bad.tsv" "$T/o2" > "$T/o2.out" 2> "$T/o2.err"; rc=$?
t "[ $rc = 1 ]" "exit 1 when a point has problems (rc=$rc)"
t "grep -q '^bad	ERROR' $T/o2.out" "bad point is an ERROR row"
t "grep -q 'no nope' $T/o2/bad/ERROR" "error names the missing settings path"
t "grep -q '^p3	PASS' $T/o2.out" "matrix continues after a failed point"
t "cmp -s $SESSION $T/session.orig" "session restored after failure"

# Signal tests wait for a known state (never a fixed sleep) and fail loudly if it is not reached or the signal is not delivered.
wait_for() {  # wait_for FILE [GREP]: up to 60 s
  n=0
  while [ "$n" -lt 600 ]; do
    if [ -n "${2:-}" ]; then grep -q "$2" "$1" 2>/dev/null && return 0; else [ -e "$1" ] && return 0; fi
    /bin/sleep 0.1; n=$((n + 1))
  done
  return 1
}
signal_case() {  # signal_case LABEL SIG OUTDIR READY_FILE GREP_OR_EMPTY HOLD(1|0): run, wait for the state, signal, check the restore
  lb=$1; sg=$2; od=$3; rf=$4; gp=$5; hold=$6
  rm -f "$T/pc/fov-matrix/session.orig.json" "$T/hold-$lb"
  if [ "$hold" = 1 ]; then export HOLD_AFTER_BACKUP="$T/hold-$lb"; else unset HOLD_AFTER_BACKUP; fi
  # EXEC=exec: the subshell becomes the runner, so $! is the runner's own pid and the signal goes straight to it (no pkill).
  ( EXEC=exec NOSTREAM=1 run "$T/ok.tsv" "$od" > "$od.out" 2> "$od.err" ) &
  RP=$!
  if wait_for "$rf" "$gp"; then check ok "$lb: runner reached the known state"; else check no "$lb: runner never reached the known state (timeout)"; fi
  if kill "-$sg" "$RP" 2>/dev/null; then check ok "$lb: SIG$sg delivered"; else check no "$lb: SIG$sg not delivered (runner already gone?)"; fi
  wait $RP
  unset HOLD_AFTER_BACKUP
  t "cmp -s $SESSION $T/session.orig" "$lb: session restored"
  t "! [ -e $T/pc/fov-matrix/session.orig.json ]" "$lb: backup file consumed"
  t "[ \$(grep -c 'restored and verified' $od/run.log) = 1 ]" "$lb: restore ran exactly once and verified"
}
echo "== SIGTERM inside the backup call (trap race)"
signal_case backup TERM "$T/o3" "$T/hold-backup" "" 1
echo "== SIGTERM after settings applied"
signal_case applied TERM "$T/o5" "$T/o5/p1/pc-apply.log" written 0
echo "== SIGHUP after settings applied"
signal_case hup HUP "$T/o6" "$T/o6/p1/pc-apply.log" written 0

echo "== stale backup refused"
mkdir -p "$T/pc/fov-matrix"; cp "$SESSION" "$T/pc/fov-matrix/session.orig.json"
run "$T/ok.tsv" "$T/o4" > "$T/o4.out" 2> "$T/o4.err"; rc=$?
t "[ $rc = 4 ]" "stale backup aborts with exit 4 (rc=$rc)"
t "grep -q 'stale backup' $T/o4.err" "message says stale backup"
t "[ -e $T/pc/fov-matrix/session.orig.json ]" "stale backup left untouched"

[ "$FAILS" = 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
