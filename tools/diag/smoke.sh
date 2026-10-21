#!/bin/sh
# Reproducible, small clips; automatically remove all generated assets and module caches.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/alvr-diag-smoke.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
export CLANG_MODULE_CACHE_PATH="$scratch/module-cache"
cd "$repo"
swift tools/diag/make-hevc-clips.swift --out "$scratch/hevc" --sizes 640x360 --fps 30 --seconds 1
swift tools/diag/make-pq-clips.swift --out "$scratch/pq" --sizes 640x360 --fps 30 --seconds 1
swift tools/diag/check-clips.swift "$scratch/hevc/hevc-manifest.json" "$scratch/pq/pq-manifest.json"
