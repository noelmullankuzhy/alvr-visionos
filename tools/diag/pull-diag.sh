#!/bin/sh
set -eu
if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo 'Usage: pull-diag.sh DEVICE_NAME_OR_ID LOCAL_DIRECTORY' >&2
    exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
    echo 'Error: xcrun is required (install/select Xcode on this Mac).' >&2
    exit 1
fi
mkdir -p "$2"
if ! xcrun devicectl device copy from --device "$1" \
    --domain-type appDataContainer --domain-identifier uk.lumenio.alvr \
    --source Documents/diag --destination "$2" --timeout 60; then
    echo "Error: could not pull Documents/diag from device '$1'. Check its name/ID, pairing, connection, unlock state, app installation, and whether diagnostics have produced logs." >&2
    exit 1
fi
