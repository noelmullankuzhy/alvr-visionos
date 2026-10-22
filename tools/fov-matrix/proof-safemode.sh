#!/bin/sh
# Proof of pc-session.py safemode-check / safemode-clear on a COPY of the real steamvr.vrsettings. Runs inside WSL on the PC:
#   ssh win-workstation wsl -e sh -s < tools/fov-matrix/proof-safemode.sh
# The real file is only read. The copy, its backup dir and the JSON output go to /mnt/c/Users/noelm/claude-tmp/vr-gaming/proof/.
# stdin carries this script, so stage pc-session.py first (no nested quoting):
#   ssh win-workstation wsl -e mkdir -p /mnt/c/Users/noelm/claude-tmp/vr-gaming/proof
#   ssh win-workstation wsl -e tee /mnt/c/Users/noelm/claude-tmp/vr-gaming/proof/pc-session.py < tools/fov-matrix/pc-session.py > /dev/null
# (override the location with PCS=...). Prints PASS or FAIL with the JSON lines. Exit 0 = PASS. Stop SteamVR first (safemode-clear refuses while it runs).
set -u
REAL="/mnt/c/Program Files (x86)/Steam/config/steamvr.vrsettings"
P=/mnt/c/Users/noelm/claude-tmp/vr-gaming/proof
PCS=${PCS:-$P/pc-session.py}
COPY=$P/steamvr.vrsettings.copy
B=$P/backups
fail() { echo "FAIL: $*"; exit 1; }

[ -f "$REAL" ] || fail "no $REAL"
[ -f "$PCS" ] || fail "no $PCS (stage tools/fov-matrix/pc-session.py there first, see the header)"
mkdir -p "$P" || fail "cannot create $P"
rm -rf "$B"
cp "$REAL" "$COPY" || fail "cannot copy the real file"

# inject the block into the copy: set it if the key is there, else add the driver entry (python3, stdlib)
python3 - "$COPY" <<'PY' || fail "cannot inject the block"
import re, sys
p = sys.argv[1]
s = open(p, 'rb').read()
if re.search(rb'"driver_alvr_server"\s*:\s*\{[^}]*?"blocked_by_safe_mode"', s):
    s = re.sub(rb'("driver_alvr_server"\s*:\s*\{[^}]*?"blocked_by_safe_mode"\s*:\s*)false', rb'\1true', s, count=1)
elif re.search(rb'"driver_alvr_server"\s*:\s*\{', s):
    s = re.sub(rb'("driver_alvr_server"\s*:\s*\{)', rb'\1\n      "blocked_by_safe_mode" : true,', s, count=1)
else:
    s = s.replace(b'{', b'{\n   "driver_alvr_server" : {\n      "blocked_by_safe_mode" : true\n   },', 1)
open(p, 'wb').write(s)
PY
cp "$COPY" "$P/steamvr.vrsettings.injected"

J1=$(python3 "$PCS" safemode-check --file "$COPY") || fail "safemode-check (before): $J1"
J2=$(python3 "$PCS" safemode-clear --file "$COPY" --backup-dir "$B") || fail "safemode-clear: $J2"
J3=$(python3 "$PCS" safemode-check --file "$COPY") || fail "safemode-check (after): $J3"
echo "check before: $J1"
echo "clear:        $J2"
echo "check after:  $J3"

case $J1 in *'"blocked": true'*) ;; *) fail "the injected block was not seen" ;; esac
case $J2 in *'"cleared": true'*) ;; *) fail "the block was not cleared" ;; esac
case $J3 in *'"blocked": false'*) ;; *) fail "still blocked after the clear" ;; esac
[ "$(ls "$B" | wc -l)" = 1 ] || fail "expected exactly one backup in $B"
cmp -s "$P/steamvr.vrsettings.injected" "$B"/steamvr.vrsettings.* || fail "the backup differs from the injected copy"
# every other byte kept: undoing the flip on the cleared copy gives the injected copy back
python3 - "$COPY" "$P/steamvr.vrsettings.injected" <<'PY' || fail "bytes other than the flag changed"
import re, sys
a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
a = re.sub(rb'("driver_alvr_server"\s*:\s*\{[^}]*?"blocked_by_safe_mode"\s*:\s*)false', rb'\1true', a, count=1)
sys.exit(0 if a == b else 1)
PY
cmp -s "$REAL" "$P/steamvr.vrsettings.injected" && echo "note: the real file was already blocked"
echo PASS
