#!/usr/bin/env bash
# Annex-B parser parity on a real device capture (GitHub issue #265).
#
# Usage: apple/bin/check-annexb-parity.sh [--typecheck] <capture.h264> [assembler.swift]
#
# Feeds the capture to the assembler in fixed chunks and in
# pseudo-random chunk sizes, and fails unless every chunking yields identical
# events. Pass another assembler copy (for example the pre-optimization source
# from `git show <rev>:apple/Sources/Pilot/Android/H264AnnexBAssembler.swift`)
# and compare its digest lines with the checked-in assembler's.
# Capture a stream with:
#   adb -s <serial> exec-out screenrecord --output-format=h264 --time-limit 10 - > capture.h264
# `--typecheck` only typechecks the harness; CI runs it so the tool keeps compiling.
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$APPLE_ROOT/Tools/AnnexBParity/main.swift"
CHECKED_IN="$APPLE_ROOT/Sources/Pilot/Android/H264AnnexBAssembler.swift"

if [[ "${1:-}" == "--typecheck" ]]; then
  exec xcrun swiftc -typecheck -swift-version 6 "$HARNESS" "${2:-$CHECKED_IN}"
fi

CAPTURE="${1:?usage: check-annexb-parity.sh [--typecheck] <capture.h264> [assembler.swift]}"
SOURCE="${2:-$CHECKED_IN}"
[[ -f "$CAPTURE" ]] || { echo "Missing capture: $CAPTURE" >&2; exit 1; }
[[ -f "$SOURCE" ]] || { echo "Missing assembler source: $SOURCE" >&2; exit 1; }

workdir="$(mktemp -d -t blau-annexb-parity.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
cp "$SOURCE" "$workdir/H264AnnexBAssembler.swift"
xcrun swiftc -O -swift-version 6 "$HARNESS" "$workdir/H264AnnexBAssembler.swift" -o "$workdir/annexb-parity"
"$workdir/annexb-parity" "$CAPTURE"
