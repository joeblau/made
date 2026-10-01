#!/usr/bin/env bash
# Optimized synthetic benchmark for the Android H.264 Annex-B assembler.
#
# Usage: apple/bin/benchmark-annexb.sh [assembler.swift]
#
# Defaults to the checked-in assembler. Pass another copy (for example
# `git show <rev>:apple/Sources/Pilot/Android/H264AnnexBAssembler.swift`
# saved to a file) to produce a comparable baseline with the same harness.
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$APPLE_ROOT/Sources/Pilot/Android/H264AnnexBAssembler.swift}"
[[ -f "$SOURCE" ]] || { echo "Missing assembler source: $SOURCE" >&2; exit 1; }

workdir="$(mktemp -d -t blau-annexb-bench.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
cp "$SOURCE" "$workdir/H264AnnexBAssembler.swift"
xcrun swiftc -O -swift-version 6 \
  "$APPLE_ROOT/Tools/AnnexBBenchmark/main.swift" \
  "$workdir/H264AnnexBAssembler.swift" \
  -o "$workdir/annexb-benchmark"
"$workdir/annexb-benchmark"
