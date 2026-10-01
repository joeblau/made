#!/usr/bin/env bash
# Benchmarks AgenticUsageLoader on a generated ~580 MB multi-provider corpus.
#
#   apple/Tools/AgenticUsageBenchmark/run.sh            # working-tree loader
#   apple/Tools/AgenticUsageBenchmark/run.sh <git-rev>  # loader at a revision
#
# The benchmark is compiled with -O against the selected loader sources. The
# corpus and binary live in a temporary directory removed on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/apple/Tools/AgenticUsageBenchmark"
SOURCES="apple/Sources/Pilot/AgenticUse"
WORK="$(mktemp -d -t agentic-usage-benchmark)"
trap 'rm -rf "$WORK"' EXIT

if [[ $# -gt 0 ]]; then
  for file in AgenticUsageLoader.swift AgenticUsageRecord.swift; do
    git -C "$ROOT" show "$1:$SOURCES/$file" > "$WORK/$file"
  done
  INPUTS=("$WORK/AgenticUsageLoader.swift" "$WORK/AgenticUsageRecord.swift")
else
  INPUTS=("$ROOT/$SOURCES/AgenticUsageLoader.swift" "$ROOT/$SOURCES/AgenticUsageRecord.swift")
fi

xcrun swiftc -O -swift-version 6 -parse-as-library \
  -o "$WORK/agentic-usage-benchmark" "$HERE/main.swift" "${INPUTS[@]}"
"$WORK/agentic-usage-benchmark" "$WORK/corpus"
