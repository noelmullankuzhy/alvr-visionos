#!/bin/sh
# Capture the Mac's AirPlay receiver window (the Vision Pro mirror) every N seconds into a folder (decision 65,
# corner chart mirror comparison). macOS only; needs Screen Recording permission for the terminal running it.
# Usage: sh tools/diag/capture-mirror.sh [-i SECONDS] [-n COUNT] [-o DIR] [-w OWNER_MATCH] [-l] [-c]
#   -i  interval in seconds, a positive decimal (default 2)   -n  captures, a whole number, 0 = until Ctrl-C (default 0)
#   -o  output folder (default ./mirror-<UTC stamp>); all scratch goes in <output>/.scratch and is removed at exit
#   -w  case-insensitive match on the window's owner or title (default airplay)
#   -l  list on-screen windows (id, owner, title, size, layer) and exit   -c  check the arguments, print them and exit
# Files: mirror-<UTC stamp>-<n>.png plus index.tsv (utc, n, window id, file).
set -eu

interval=2
count=0
out=""
match=airplay
list=0
check=0
while getopts "i:n:o:w:lch" opt; do
    case "$opt" in
        i) interval=$OPTARG ;;
        n) count=$OPTARG ;;
        o) out=$OPTARG ;;
        w) match=$OPTARG ;;
        l) list=1 ;;
        c) check=1 ;;
        *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    esac
done
case "$count" in
    ''|*[!0-9]*) echo "Error: -n takes a whole number of captures (0 = until Ctrl-C), got '$count'." >&2; exit 2 ;;
esac
# Digits with at most one point and at least one digit (2, 0.5, .5, 2.), and not zero.
case "$interval" in
    ''|.|*[!0-9.]*|*.*.*) echo "Error: -i takes a positive number of seconds, got '$interval'." >&2; exit 2 ;;
esac
case "$interval" in
    *[1-9]*) ;;
    *) echo "Error: -i takes a positive number of seconds, got '$interval'." >&2; exit 2 ;;
esac
[ -n "$out" ] || out="mirror-$(date -u +%Y%m%dT%H%M%SZ)"
if [ "$check" -eq 1 ]; then
    echo "interval=$interval count=$count out=$out match=$match list=$list"
    exit 0
fi
if [ "$(uname -s)" != Darwin ]; then
    echo "Error: macOS only (screencapture)." >&2
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1 || ! command -v screencapture >/dev/null 2>&1; then
    echo "Error: needs xcrun (Xcode command line tools) and screencapture." >&2
    exit 1
fi

made_out=0
[ -d "$out" ] || made_out=1
work="$out/.scratch"
mkdir -p "$work/tmp" "$work/mc"
# Leaves no scratch behind; an output folder made only for -l (or a failed start) is removed again when empty.
cleanup() {
    rm -rf "$work"
    if [ "$made_out" -eq 1 ]; then rmdir "$out" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
cat > "$work/listwin.swift" <<'SWIFT'
import CoreGraphics
import Foundation
print("screen_recording=\(CGPreflightScreenCaptureAccess())")
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows {
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.intValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.intValue ?? 0
    let fields = ["\((w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)",
                  (w[kCGWindowOwnerName as String] as? String) ?? "", (w[kCGWindowName as String] as? String) ?? "",
                  "\(width)x\(height)", "\((w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)"]
    print(fields.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t"))
}
SWIFT
if ! TMPDIR="$work/tmp" CLANG_MODULE_CACHE_PATH="$work/mc" xcrun swiftc -O -module-cache-path "$work/mc" \
        -o "$work/listwin" "$work/listwin.swift" 2>"$work/swiftc.err"; then
    echo "Error: could not build the window lister:" >&2
    cat "$work/swiftc.err" >&2
    exit 1
fi
"$work/listwin" > "$work/windows.txt"

if [ "$list" -eq 1 ]; then
    sed -n '2,$p' "$work/windows.txt"
    exit 0
fi
if ! grep -q '^screen_recording=true$' "$work/windows.txt"; then
    echo "Error: no Screen Recording permission. Allow your terminal in System Settings > Privacy & Security >" >&2
    echo "Screen & System Audio Recording, then restart the terminal and rerun." >&2
    exit 1
fi

find_window() {
    "$work/listwin" | sed -n '2,$p' | awk -F '\t' -v pat="$match" '
        index(tolower($2), tolower(pat)) || index(tolower($3), tolower(pat)) {
            split($4, s, "x"); a = s[1] * s[2]
            if (a > best) { best = a; id = $1 }
        }
        END { if (id != "") print id }'
}

id=$(find_window)
if [ -z "$id" ]; then
    echo "Error: no on-screen window matching '$match'. Start mirroring the Vision Pro to this Mac (Control Centre >" >&2
    echo "Mirror My View > this Mac, AirPlay Receiver on), or run with -l to list windows and pass -w OWNER." >&2
    exit 1
fi

[ -f "$out/index.tsv" ] || printf 'utc\tn\twindow_id\tfile\n' > "$out/index.tsv"
echo "Capturing window $id every ${interval}s into $out (Ctrl-C to stop)."
n=0
while [ "$count" -eq 0 ] || [ "$n" -lt "$count" ]; do
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    file="mirror-$stamp-$n.png"
    if ! screencapture -x -o -l "$id" "$out/$file" 2>"$work/cap.err" || [ ! -s "$out/$file" ]; then
        # The window can be recreated when mirroring restarts: look it up once more before giving up.
        id=$(find_window)
        if [ -z "$id" ] || ! screencapture -x -o -l "$id" "$out/$file" 2>"$work/cap.err" || [ ! -s "$out/$file" ]; then
            echo "Error: capture failed (mirror window gone or Screen Recording denied):" >&2
            cat "$work/cap.err" >&2
            exit 1
        fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$stamp" "$n" "$id" "$file" >> "$out/index.tsv"
    n=$((n + 1))
    sleep "$interval"
done
echo "Captured $n images into $out."
