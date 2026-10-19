#!/bin/sh
# Build capture-ios-fake (the app's shared Swift code + a fake camera) with the Command Line Tools swiftc, run the unchanged director against it.
# Usage: tools/capture-ios/tests/run.sh [shared-sources-dir]   (the optional dir lets a planted-fault copy be tested)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../Sources/Shared}
OUT=${TMPDIR:-/tmp}/capture-ios-fake-build; mkdir -p "$OUT"
swiftc -O -o "$OUT/capture-ios-fake" "$SRC"/*.swift "$HERE/../Sources/Fake/main.swift"
python3 "$HERE/test_director_ios.py" "$OUT/capture-ios-fake"
