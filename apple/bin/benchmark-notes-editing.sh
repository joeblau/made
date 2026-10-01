#!/usr/bin/env bash
# Profiles main-thread Notes edit latency (issue #266). Compiles the Notes
# editor sources with apple/Tools/NotesEditBenchmark/main.swift as an optimized
# command-line tool and prints per-keystroke timings for a small note and a
# long mixed-content note. Not part of CI: timings depend on the machine.
#
# Usage: apple/bin/benchmark-notes-editing.sh [label] [workload]
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/made-notes-edit-benchmark"
mkdir -p "$OUT"

sources=(
  MarkdownStyler EnvSecret ColorChip MarkdownImage MarkdownTableFormatter
  MultiCursorTextView NoteEditorOverlays MarkdownImagePreview NoteCaretAnchor
)
paths=("$APPLE_ROOT/Tools/NotesEditBenchmark/main.swift")
for source in "${sources[@]}"; do paths+=("$APPLE_ROOT/Sources/Pilot/$source.swift"); done

xcrun swiftc -O -swift-version 6 -o "$OUT/notes-edit-benchmark" "${paths[@]}"
exec "$OUT/notes-edit-benchmark" "$@"
