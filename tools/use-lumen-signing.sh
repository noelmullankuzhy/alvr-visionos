#!/bin/sh
# Writes a local (gitignored) Override.xcconfig that selects Lumen.xcconfig.
# Idempotent; refuses to overwrite a different existing Override.xcconfig.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
override="$root/Override.xcconfig"
line='#include "Lumen.xcconfig"'

if [ -e "$override" ]; then
    if [ "$(cat "$override")" = "$line" ]; then
        echo "Override.xcconfig already selects Lumen.xcconfig"
        exit 0
    fi
    echo "refusing to overwrite existing $override (different content)" >&2
    exit 1
fi

printf '%s\n' "$line" > "$override"
echo "wrote $override"
