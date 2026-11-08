#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: apple/bin/benchmark-ci.sh NEW_EVIDENCE_DIRECTORY" >&2
  exit 2
fi

REPO_ROOT="$(pwd)"
[[ -x "$REPO_ROOT/apple/bin/build-ci.sh" && -x "$REPO_ROOT/apple/bin/test.sh" ]] || {
  echo "Run from the root of the checkout being measured." >&2
  exit 2
}
[[ ! -e "$1" ]] || {
  echo "Evidence directory already exists; choose a new path for a clean run: $1" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_XCODEBUILD="$(command -v xcodebuild)"
mkdir -p "$1"
EVIDENCE_DIR="$(cd "$1" && pwd)"
mkdir -p "$EVIDENCE_DIR/logs" "$EVIDENCE_DIR/tools"
ln -s "$SCRIPT_DIR/lib/xcodebuild-benchmark.sh" "$EVIDENCE_DIR/tools/xcodebuild"

export BLAU_DERIVED_DATA="$EVIDENCE_DIR/derived-data"
export BLAU_SOURCE_PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"
export BLAU_CI_BENCHMARK_DIR="$EVIDENCE_DIR"
export BLAU_CI_BENCHMARK_XCODEBUILD="$REAL_XCODEBUILD"
export PATH="$EVIDENCE_DIR/tools:$PATH"
mkdir -p "$BLAU_SOURCE_PACKAGES"

{
  printf 'revision='
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
  printf 'architecture=%s\n' "$(uname -m)"
  printf 'runner_image=%s\n' "${ImageVersion:-unknown}"
  sw_vers
  "$REAL_XCODEBUILD" -version
} > "$EVIDENCE_DIR/environment.txt"

grep -q '^Xcode 27\.' "$EVIDENCE_DIR/environment.txt" || {
  echo "The paired benchmark requires the supported Xcode 27 toolchain." >&2
  exit 1
}

printf 'phase\taction\tscheme\tswift_compile\tcompile_c\tcompile_units\twall_seconds\tstatus\tlog\n' \
  > "$EVIDENCE_DIR/commands.tsv"
printf 'phase\twall_seconds\tstatus\n' > "$EVIDENCE_DIR/steps.tsv"

run_step() {
  local phase="$1"
  local started status
  shift
  started=$SECONDS
  status=0
  if "$@"; then
    status=0
  else
    status=$?
  fi
  printf '%s\t%s\t%s\n' "$phase" "$((SECONDS - started))" "$status" \
    >> "$EVIDENCE_DIR/steps.tsv"
  return "$status"
}

run_step build "$REPO_ROOT/apple/bin/build-ci.sh"
run_step test "$REPO_ROOT/apple/bin/test.sh" all
cat "$EVIDENCE_DIR/steps.tsv" "$EVIDENCE_DIR/totals.tsv"
