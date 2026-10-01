#!/usr/bin/env bash
# Optimized synthetic benchmark for the Android H.264 Annex-B assembler.
#
# Usage: apple/bin/benchmark-annexb.sh [--typecheck] [assembler.swift]
#
# Defaults to the checked-in assembler. Pass another copy (for example
# `git show <rev>:apple/Sources/Pilot/Android/H264AnnexBAssembler.swift`
# saved to a file) to produce a comparable baseline with the same harness.
# `--typecheck` only typechecks the harness against the assembler; CI runs it
# from apple/bin/build-ci.sh so the benchmark cannot silently stop compiling.
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TYPECHECK=0
if [[ "${1:-}" == "--typecheck" ]]; then
  TYPECHECK=1
  shift
fi
SOURCE="${1:-$APPLE_ROOT/Sources/Pilot/Android/H264AnnexBAssembler.swift}"
[[ -f "$SOURCE" ]] || { echo "Missing assembler source: $SOURCE" >&2; exit 1; }

if [[ "$TYPECHECK" == 1 ]]; then
  exec xcrun swiftc -typecheck -swift-version 6 \
    "$APPLE_ROOT/Tools/AnnexBBenchmark/main.swift" "$SOURCE"
fi

workdir="$(mktemp -d -t blau-annexb-bench.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
cp "$SOURCE" "$workdir/H264AnnexBAssembler.swift"
xcrun swiftc -O -swift-version 6 \
  "$APPLE_ROOT/Tools/AnnexBBenchmark/main.swift" \
  "$workdir/H264AnnexBAssembler.swift" \
  -o "$workdir/annexb-benchmark"
"$workdir/annexb-benchmark"
