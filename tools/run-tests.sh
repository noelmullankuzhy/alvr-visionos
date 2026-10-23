#!/bin/sh
# Unified local checks. Set SWIFT_SKIP_TESTS=HDRGPUTests only where Metal is unavailable.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
sh tests/swift/run-tests.sh
for interpreter in /usr/bin/python3 /opt/homebrew/bin/python3; do
    "$interpreter" tools/diag/test_netprobe.py
    "$interpreter" tools/diag/test_noise.py
    "$interpreter" tools/tests/test_brighttrace.py
done
