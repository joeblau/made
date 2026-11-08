#!/usr/bin/env bash
# Profiles main-thread Notes edit latency (issue #266). Compiles the Notes
# editor sources with apple/Tools/NotesEditBenchmark/main.swift as an optimized
# command-line tool and prints raw per-keystroke samples, median, and p95 for a
# small note and a long mixed-content note. Not part of CI: timings depend on
# the machine. Set MADE_SOURCE_ROOT to another checkout's apple directory to
# compile its production sources with this runner.
#
# Usage: apple/bin/benchmark-notes-editing.sh [label] [workload] [all|small|long]
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${MADE_SOURCE_ROOT:-$APPLE_ROOT}"
OUT="${MADE_BENCHMARK_OUT:-${TMPDIR:-/tmp}/made-notes-edit-benchmark}"
mkdir -p "$OUT"

sources=(
  MarkdownStyler EnvSecret ColorChip MarkdownImage MarkdownTableFormatter
  MarkdownImagePreview NoteCaretAnchor
)
if [[ -f "$SOURCE_ROOT/Sources/Pilot/NotesEditorTextView.swift" ]]; then
  sources+=(NotesEditorTextView NotesGutter NotesTextReflow)
else
  sources+=(MultiCursorTextView NoteEditorOverlays)
fi
paths=("$APPLE_ROOT/Tools/NotesEditBenchmark/main.swift")
for source in "${sources[@]}"; do paths+=("$SOURCE_ROOT/Sources/Pilot/$source.swift"); done
if [[ -f "$SOURCE_ROOT/Sources/Shared/LiquidGlassMetrics.swift" ]]; then
  paths+=("$SOURCE_ROOT/Sources/Shared/LiquidGlassMetrics.swift")
fi

flags=(-O -swift-version 6)
if grep -q 'var secretMatches:' "$SOURCE_ROOT/Sources/Pilot/MarkdownStyler.swift"; then
  flags+=(-D NOTES_EDITOR_HAS_STRUCTURE_INDEX)
fi

printf 'Source root: %s\n' "$SOURCE_ROOT"
xcrun swiftc "${flags[@]}" -o "$OUT/notes-edit-benchmark" "${paths[@]}"
exec "$OUT/notes-edit-benchmark" "$@"
