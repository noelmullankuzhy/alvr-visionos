#!/bin/sh
# Pure-Swift unit tests for client helpers, compiled and run on macOS (the app has no Xcode test target).
# Each tests/swift/<Name>Tests.swift declares the app sources it needs on one line:
#   // SOURCES: ALVRClient/Foo.swift ALVRClient/Bar.swift
# and optionally a Metal file to compile for the Mac GPU (its metallib path is the test's first argument):
#   // METAL: tests/swift/Foo.metal
# and provides `@main enum <Name>Tests { static func main() { ...; finishTests("<Name>") } }`.
# Helpers under test must import only Foundation/simd so they build for macOS.
# Usage (repo root): sh tests/swift/run-tests.sh [Name]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="$1"
OUT="$ROOT/build/chart-octagon/swift-tests"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/build/clang-module-cache}"
fail=0
ran=0
for t in "$ROOT"/tests/swift/*Tests.swift; do
  [ -e "$t" ] || continue
  name=$(basename "$t" .swift)
  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ] && [ "$name" != "${FILTER}Tests" ]; then
    continue
  fi
  # Explicit opt-out for hardware unavailable in a worker sandbox; normal runs skip nothing.
  case ",${SWIFT_SKIP_TESTS:-}," in
    *,"$name",*) echo "SKIP $name (SWIFT_SKIP_TESTS)"; continue ;;
  esac
  srcs=""
  for s in $(sed -n 's#^// SOURCES: ##p' "$t" | head -1); do
    srcs="$srcs $ROOT/$s"
  done
  # shellcheck disable=SC2086
  xcrun swiftc -parse-as-library -swift-version 5 -o "$OUT/$name" "$ROOT/tests/swift/TestSupport.swift" $srcs "$t"
  # Optional `// METAL: tests/swift/Foo.metal`: compiled for the Mac GPU, the metallib path passed as argument 1.
  metal=$(sed -n 's#^// METAL: ##p' "$t" | head -1)
  if [ -n "$metal" ]; then
    xcrun -sdk macosx metal -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -o "$OUT/$name.metallib" "$ROOT/$metal"
    if "$OUT/$name" "$OUT/$name.metallib"; then :; else fail=1; fi
  elif "$OUT/$name"; then :; else fail=1; fi
  ran=$((ran + 1))
done
echo "swift test files run: $ran"
[ "$ran" -gt 0 ] || { echo "NO TESTS MATCHED"; exit 1; }
[ "$fail" -eq 0 ] && echo SWIFT_TESTS_OK
exit "$fail"
