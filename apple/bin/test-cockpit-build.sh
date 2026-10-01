#!/usr/bin/env bash
# Exercise build orchestration without downloading CEF or invoking a compiler.
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cockpit-build-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/apple/bin" "$work/tools"
cp "$APPLE_ROOT/bin/build-pilot-chromium.sh" "$work/apple/bin/"
export COCKPIT_TEST_LOG="$work/calls"
export COCKPIT_TEST_STATE="$work"
export PATH="$work/tools:$PATH"
cat > "$work/tools/xcodebuild" <<'TOOL'
#!/bin/bash
if [[ "${1:-}" == -version ]]; then
  printf 'Xcode 26.6\n'
else
  printf '%s\n' xcodebuild "$@" >> "$COCKPIT_TEST_LOG"
fi
TOOL
cat > "$work/apple/bin/verify-installed-chromiumkit.sh" <<'TOOL'
#!/bin/bash
printf 'verify\n' >> "$COCKPIT_TEST_LOG"
[[ ! -f "$COCKPIT_TEST_STATE/invalid-runtime" ]]
TOOL
cat > "$work/apple/bin/update-chromiumkit-artifact.sh" <<'TOOL'
#!/bin/bash
printf 'update\n' >> "$COCKPIT_TEST_LOG"
[[ ! -f "$COCKPIT_TEST_STATE/failed-update" ]]
TOOL
cat > "$work/apple/bin/install-xcodegen.sh" <<'TOOL'
#!/bin/bash
printf '%s\n' xcodegen "$@" >> "$COCKPIT_TEST_LOG"
TOOL
chmod +x "$work/tools/xcodebuild" "$work/apple/bin/"*.sh
build="$work/apple/bin/build-pilot-chromium.sh"
assert_absent() {
  if grep -q -- "$1" "$COCKPIT_TEST_LOG"; then
    printf 'Unexpected build invocation: %s\n' "$1" >&2
    exit 1
  fi
}

# A verified runtime is reused, and release settings are left to the project.
"$build" -quiet
assert_absent '^update$'
assert_absent 'SWIFT_OPTIMIZATION_LEVEL='
grep -qx -- --use-cache "$COCKPIT_TEST_LOG"
grep -qx -- -onlyUsePackageVersionsFromResolvedFile "$COCKPIT_TEST_LOG"
grep -qx -- -quiet "$COCKPIT_TEST_LOG"

# Local compilation is incremental and host-only, with a relocatable cache.
: > "$COCKPIT_TEST_LOG"
BLAU_PILOT_DERIVED_DATA="$work/cache with spaces" "$build" --local
assert_absent '^--local$'
grep -qx "ARCHS=$(uname -m)" "$COCKPIT_TEST_LOG"
grep -qx SWIFT_COMPILATION_MODE=incremental "$COCKPIT_TEST_LOG"
grep -qx SWIFT_OPTIMIZATION_LEVEL=-O "$COCKPIT_TEST_LOG"
grep -qx "$work/cache with spaces" "$COCKPIT_TEST_LOG"
grep -qx BLAU_CHROMIUM_CODESIGN_TIMESTAMP=NO "$COCKPIT_TEST_LOG"

# Missing, stale or corrupt installations take the verified installer path.
: > "$COCKPIT_TEST_LOG"
touch "$work/invalid-runtime"
"$build" --local
grep -qx update "$COCKPIT_TEST_LOG"
grep -qx xcodebuild "$COCKPIT_TEST_LOG"

# Never continue compiling after a failed runtime update.
: > "$COCKPIT_TEST_LOG"
touch "$work/failed-update"
if "$build" --local; then
  printf 'Expected runtime update failure\n' >&2
  exit 1
fi
assert_absent '^xcodebuild$'
printf 'Cockpit build orchestration checks passed\n'
