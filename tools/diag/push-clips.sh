#!/bin/sh
set -eu
if [ "$#" -ne 2 ] || [ -z "$1" ] || [ ! -d "$2" ]; then
    echo 'Usage: push-clips.sh DEVICE_NAME_OR_ID LOCAL_CLIP_DIRECTORY' >&2
    exit 2
fi
if ! xcrun devicectl device copy to --device "$1" \
    --domain-type appDataContainer --domain-identifier uk.lumenio.alvr \
    --source "$2" --destination Documents/diag-clips --timeout 60; then
    echo 'Error: clip copy failed. Check device pairing, unlock state and app installation.' >&2
    exit 1
fi
