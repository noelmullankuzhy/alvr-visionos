#!/bin/sh
# run-ladder.sh with stub ssh/xcrun/harness (no PC, no headset): the live path end to end. Happy path (two rungs: summary
# rows, device stats pulled, session restored byte for byte), a rung whose client never connects, a stale telemetry file
# (an earlier session's must not be used), a failing devicectl copy, and SIGTERM mid-run.
#   sh tools/fov-matrix/test-ladder-stubs.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ladder-stub.XXXXXX") || exit 2
T=$(CDPATH= cd -- "$T" && pwd) || exit 2
if [ "${1:-}" = --keep ]; then echo "keeping $T"; else trap 'rm -rf "$T"' EXIT; fi
FAILS=0
check() { if [ "$1" = ok ]; then echo "ok   $2"; else echo "FAIL $2"; FAILS=$((FAILS + 1)); fi; }
t() { if eval "$1"; then check ok "$2"; else check no "$2"; fi; }

mkdir -p "$T/bin" "$T/harness" "$T/pc/alvr-build/out/b1/alvr_streamer_windows" "$T/dev"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = -N ] && exec /bin/sleep 600; done
s=$FAKE_PC/.ssh-script.$$; cat > "$s"
FOVMATRIX_PC_ROOT=$FAKE_PC sh "$s"; rc=$?
if grep -q ' python3 - flag ' "$s"; then cat "$FAKE_PC/alvr-build/out/b1/alvr_streamer_windows/angle_chart.enable" >> "$FAKE_PC/flag.history" 2>/dev/null || echo absent >> "$FAKE_PC/flag.history"; fi
rm -f "$s"; exit $rc
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
exec /bin/sleep 0.2
EOF
# devicectl: launch records its arguments; copy from writes the fake app container's Documents/telemetry into the destination
cat > "$T/bin/xcrun" <<'EOF'
#!/bin/sh
[ "$1" = devicectl ] || exit 0
case "$3" in
  process) echo "$*" >> "$FAKE_DEV/launch.args"; [ -n "${LAUNCH_FAIL:-}" ] && { echo 'ERROR: device is locked'; exit 1; }; echo launched ;;
  copy)
    [ -n "${COPY_FAIL:-}" ] && { echo 'ERROR: no such device'; exit 1; }
    echo "$*" >> "$FAKE_DEV/copy.args"
    for a in "$@"; do last=$a; done
    dest=
    while [ $# -gt 0 ]; do [ "$1" = --destination ] && dest=$2; shift; done
    cp "$FAKE_DEV"/telemetry/*.jsonl "$dest"/ 2>/dev/null
    echo copied ;;
esac
exit 0
EOF
cat > "$T/harness/alvr-run2.py" <<'EOF'
import sys
EOF
# ws-probe stub: 10 StatisticsSummary lines with the NVENC timer (7 ms), client_fps 90 unless NOCLIENT
cat > "$T/harness/ws-probe.py" <<'EOF'
import json, os, sys
with open(sys.argv[3], 'w') as f:
    for i in range(10):
        d = {'video_packets_total': 100, 'video_mbits_per_sec': 299.0, 'encode_latency_ms': 9.5, 'client_fps': 0 if os.environ.get('NOCLIENT') else 90, 'encode_nvenc_ms': 7.0}
        f.write(json.dumps({'event_type': {'id': 'StatisticsSummary', 'data': d}}) + '\n')
EOF
: > "$T/harness/pc-alvr-manualip.ps1"
cat > "$T/pcps.sh" <<'PCPS'
case $1 in
  *pc-dashboard-wait.ps1) echo 'api ok after 1s' ;;
  *pc-steamvr-stop.ps1) echo 'steamvr: graceful stop in 2s' ;;
esac
exit 0
PCPS
printf '{\n   "driver_alvr_server" : {\n      "blocked_by_safe_mode" : true\n   }\n}\n' > "$T/vrsettings"
cat > "$T/bin/tasklist.exe" <<'TL'
#!/bin/sh
echo 'Image Name  PID'
exit 0
TL
chmod +x "$T/bin/"*

cat > "$T/mk.py" <<'EOF'
import json, sys
res = lambda: {'variant': 'Absolute', 'Scale': 1.0, 'Absolute': {'width': 1, 'height': {'enabled': True, 'content': 1}}}
json.dump({'session_settings': {'video': {
    'preferred_codec': {'variant': 'H264'},
    'encoder_config': {'use_10bit': False, 'server_overrides_use_10bit': False,
                       'nvenc': {'quality_preset': {'variant': 'P4'}, 'multi_pass': {'variant': 'QuarterResolution'}, 'split_encode_mode': {'variant': 'Auto'}}},
    'preferred_fps': 72.0, 'bitrate': {'mode': {'variant': 'Adaptive', 'ConstantMbps': 30}},
    'foveated_encoding': {'enabled': True, 'content': {'center_size_x': 0.4, 'center_size_y': 0.4, 'edge_ratio_x': 4.0,
                                                       'edge_ratio_y': 4.0, 'center_shift_x': 0.0, 'center_shift_y': 0.0}},
    'transcoding_view_resolution': res(), 'emulated_headset_view_resolution': res(),
}}}, open(sys.argv[1], 'w'), indent=2)
# the device's telemetry: an old session and the current one (names are UTC; "current" sorts last and is far in the future)
def stat(i, p95):
    return json.dumps({'type': 'stats', 't': float(i), 'frames_received': 90, 'frames_dropped': 0, 'presented_fps': 90.0, 'decode_ms_mean': 6.0, 'decode_ms_p95': p95})
open(sys.argv[2] + '/20200101T000000Z.jsonl', 'w').write('\n'.join(stat(i, 50.0) for i in range(100)) + '\n')   # stale: p95 50 ms would FAIL
open(sys.argv[2] + '/20990101T000000Z.jsonl', 'w').write(json.dumps({'type': 'format'}) + '\n' + '\n'.join(stat(i, 9.0) for i in range(100)) + '\n')
EOF
SESSION=$T/pc/alvr-build/out/b1/alvr_streamer_windows/session.json
mkdir -p "$T/dev/telemetry"
python3 "$T/mk.py" "$SESSION" "$T/dev/telemetry"
cp "$SESSION" "$T/session.orig"

# two rungs from the real file
grep -E '^(dC-p1-100|dT-p1-500)	' "$HERE/points-device-ladder.tsv" > "$T/two.tsv"

run() {  # run OUTDIR [extra args]
  od=$1; shift
  PATH="$T/bin:$PATH" PCW="$T/pc/fov-matrix" FAKE_PC="$T/pc" FAKE_DEV="$T/dev" HARNESS="$T/harness" PCPS="$T/pcps.sh" VRSETTINGS="$T/vrsettings" VRSERVER_LOG="$T/vrserver.txt" \
    ${EXEC:-} sh "$HERE/run-ladder.sh" --points "${TSV:-$T/two.tsv}" --out "$od" --build b1 --settle 1 --probe-seconds 5 --connect-timeout 10 --operator-after 5 "$@"
}

echo "== happy path"
run "$T/o1" > "$T/o1.out" 2> "$T/o1.err"; rc=$?
t "[ $rc = 0 ]" "exit 0 (rc=$rc)"
t "[ \$(wc -l < $T/o1.out) = 3 ]" "stdout is the summary only (header + 2 rows)"
t "grep -q '^dC-p1-100	PASS	7.00	7.00	9.50' $T/o1.out" "dC row PASS with NVENC 7.00 / latency 9.50 from the server events"
t "grep -q '^dT-p1-500	PASS' $T/o1.out" "dT row PASS"
t "grep -q '	6.00	9.00	9.00	0	0.00	90.0	299.0	5	' $T/o1.out" "device columns from the newest telemetry file, last 5 windows, bitrate from the server"
t "cmp -s $SESSION $T/session.orig" "session restored byte for byte"
t "grep -q 'launch --device 00008112-001E456E0C21A01E --terminate-existing uk.lumenio.alvr -ALVRAutoEnter YES -ALVRAutoEnterRenderer metal' $T/dev/launch.args" "client launched with the auto-enter arguments"
t "! grep -q DebugEyeTangents $T/dev/launch.args" "no debug tangents on the device"
t "grep -q 'source Documents/telemetry' $T/dev/copy.args || grep -q -- '--source Documents/telemetry' $T/dev/copy.args" "telemetry directory pulled with devicectl copy from"
t "grep -q 'domain-type appDataContainer --domain-identifier uk.lumenio.alvr' $T/dev/copy.args" "from the app data container"
t "grep -q '^video.encoder_config.nvenc.quality_preset={\"variant\":\"P1\"}' $T/o1/dC-p1-100/sets.txt" "rung sets written"
t "! grep -q dump $T/pc/flag.history && ! grep -q stress $T/pc/flag.history" "chart flag never on (no dumps while measuring)"
t "[ -s $T/o1/dC-p1-100/device-stats.jsonl ] && [ -s $T/o1/dC-p1-100/events.jsonl ] && [ -s $T/o1/dC-p1-100/summary.tsv ]" "per-rung dir has sets, events, device stats, row"
t "[ ! -e $T/pc/fov-matrix/session.orig.json ]" "no backup left on the PC"

echo "== client never connects"
( NOCLIENT=1; export NOCLIENT; run "$T/o2" > "$T/o2.out" 2> "$T/o2.err" ); rc=$?
t "[ $rc = 1 ]" "exit 1 (rc=$rc)"
t "grep -q '^OPERATOR:' $T/o2.err" "one OPERATOR line printed"
t "[ \$(grep -c '^OPERATOR:' $T/o2.err) = 2 ]" "once per rung"
t "grep -q 'client: no client_fps' $T/o2/dC-p1-100/ERROR" "rung error says no client"
t "grep -q '^dC-p1-100	ERROR' $T/o2.out" "summary row ERROR"
t "cmp -s $SESSION $T/session.orig" "session restored after failed rungs"

echo "== devicectl launch fails: operator line, run goes on"
( LAUNCH_FAIL=1; export LAUNCH_FAIL; run "$T/o3" --only dC-p1-100 > "$T/o3.out" 2> "$T/o3.err" ); rc=$?
t "[ $rc = 0 ] && grep -q 'OPERATOR: devicectl could not launch' $T/o3.err" "launch failure -> OPERATOR line, stream still measured (rc=$rc)"

echo "== devicectl copy fails"
( COPY_FAIL=1; export COPY_FAIL; run "$T/o4" --only dC-p1-100 > "$T/o4.out" 2> "$T/o4.err" ); rc=$?
t "[ $rc = 1 ] && grep -q 'devicectl copy of Documents/telemetry failed' $T/o4/dC-p1-100/ERROR" "copy failure is an ERROR row (rc=$rc)"
t "grep -q '^dC-p1-100	ERROR' $T/o4.out" "row says ERROR, not a pass"

echo "== only the stale file on the device"
rm -f "$T/dev/telemetry/20990101T000000Z.jsonl"
run "$T/o5" --only dC-p1-100 > "$T/o5.out" 2> "$T/o5.err"; rc=$?
t "[ $rc = 1 ] && grep -q 'no stats windows in a telemetry file at or after' $T/o5/dC-p1-100/ERROR" "an earlier session's file is not taken (rc=$rc)"
python3 "$T/mk.py" "$T/scratch.json" "$T/dev/telemetry"

echo "== SIGTERM mid-run restores"
( run "$T/o6" --connect-timeout 60 > "$T/o6.out" 2> "$T/o6.err" ) &
sleep 1; n=0
while [ ! -f "$T/pc/fov-matrix/session.orig.json" ] && [ $n -lt 50 ]; do /bin/sleep 0.2; n=$((n + 1)); done
pkill -TERM -f "run-ladder.sh --points $T/two.tsv --out $T/o6" 2>/dev/null
wait
t "cmp -s $SESSION $T/session.orig" "session restored after SIGTERM"

echo "== bad input"
sh "$HERE/run-ladder.sh" --out "$T/o7" > /dev/null 2>&1; t "[ $? = 2 ]" "no --points -> exit 2"
sh "$HERE/run-ladder.sh" --points "$T/two.tsv" --out "$T/o7" --only nope > /dev/null 2>&1; t "[ $? != 0 ]" "--only with no match fails"

if [ $FAILS = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
