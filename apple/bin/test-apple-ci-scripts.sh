#!/usr/bin/env bash
# Exercise build-ci.sh/test.sh orchestration without invoking a compiler:
# shared per-platform derived data, pinned policy flags, and the guarantee that
# test-without-building only follows a successful build-for-testing of the same
# products in the same invocation.
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/apple-ci-scripts-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/apple/bin/lib" "$work/tools"
cp "$APPLE_ROOT/bin/build-ci.sh" "$APPLE_ROOT/bin/test.sh" "$work/apple/bin/"
cp "$APPLE_ROOT/bin/lib/xcodebuild-ci.sh" "$work/apple/bin/lib/"
export CI_TEST_LOG="$work/calls"
export CI_TEST_ACTIONS="$work/actions"
export PATH="$work/tools:$PATH"
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
unset BLAU_DERIVED_DATA BLAU_SOURCE_PACKAGES
export IOS_SIMULATOR_UDID=00000000-0000-0000-0000-000000000000
export IPAD_SIMULATOR_UDID=11111111-1111-1111-1111-111111111111

cat > "$work/tools/xcodebuild" <<'TOOL'
#!/bin/bash
printf 'xcodebuild DISABLE_SWIFTLINT=%s %s\n' "${DISABLE_SWIFTLINT:-}" "$*" >> "$CI_TEST_LOG"
action="$1"
derived=""
scheme=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == -derivedDataPath ]] && derived="$2"
  [[ "$1" == -scheme ]] && scheme="$2"
  shift
done
printf '%s %s\n' "$action" "$scheme" >> "$CI_TEST_ACTIONS"
if [[ "$action" == "${CI_TEST_FAIL_ACTION:-}" ]]; then
  [[ "$action" == test ]] && mkdir -p "$derived/Logs/Test/failed.xcresult"
  exit 65
fi
if [[ "$action" == build-for-testing ]]; then
  mkdir -p "$derived/Build/Products"
  touch "$derived/Build/Products/${scheme}_iphonesimulator27.0-arm64-x86_64.xctestrun"
fi
TOOL
cat > "$work/tools/xcrun" <<'TOOL'
#!/bin/bash
printf 'xcrun %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/app-icon-tool.swift" <<'TOOL'
#!/bin/bash
printf 'icons %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/fetch-runner-model.sh" <<'TOOL'
#!/bin/bash
printf 'runner-model %s\n' "$*" >> "$CI_TEST_LOG"
TOOL
cat > "$work/apple/bin/check-cockpit-ui-boundary.py" <<'TOOL'
import os
from pathlib import Path
with Path(os.environ["CI_TEST_LOG"]).open("a") as log:
    log.write("cockpit-ui-boundary\n")
raise SystemExit(int(os.environ.get("CI_TEST_BOUNDARY_FAILURE", "0")))
TOOL
cat > "$work/apple/bin/test-drone-protocol.sh" <<'TOOL'
#!/bin/bash
printf 'drone-protocol\n' >> "$CI_TEST_LOG"
TOOL
for proof in drone-launchd drone-jobs drone-terminal drone-tools drone-worker; do
  cat > "$work/apple/bin/test-$proof.sh" <<'TOOL'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$CI_TEST_LOG"
TOOL
done
chmod +x "$work/tools/"* "$work/apple/bin/"*.sh "$work/apple/bin/app-icon-tool.swift"

fail() { printf 'apple CI script test: %s\n' "$*" >&2; exit 1; }
calls() { grep -c -- "$1" "$CI_TEST_LOG" || true; }
expect_calls() {
  local count
  count="$(calls "$2")"
  [[ "$count" == "$1" ]] || fail "expected $1 call(s) matching '$2', saw $count"
}
expect_actions() {
  local actual
  actual="$(cat "$CI_TEST_ACTIONS")"
  [[ "$actual" == "$1" ]] || fail "unexpected xcodebuild actions: $actual"
}
reset_log() {
  : > "$CI_TEST_LOG"
  : > "$CI_TEST_ACTIONS"
}

root="$TMPDIR/blau-apple-ci"
macos="-derivedDataPath $root/macos-debug "
simulator="-derivedDataPath $root/ios-simulator-debug "
generic="-destination generic/platform=iOS Simulator"

# The CI lane: build every application, then run every hosted suite.
reset_log
"$work/apple/bin/build-ci.sh"
"$work/apple/bin/test.sh" all
expect_calls 1 '^icons validate$'
expect_calls 1 '^runner-model verify$'
expect_calls 2 '^cockpit-ui-boundary$'
expect_calls 1 '^drone-protocol$'
expect_calls 1 '^test-drone-launchd.sh$'
expect_calls 1 '^test-drone-jobs.sh$'
expect_calls 1 '^test-drone-terminal.sh$'
expect_calls 1 '^test-drone-tools.sh$'
expect_calls 1 '^test-drone-worker.sh$'
expect_calls 10 '^xcodebuild '
expect_calls 10 '^xcodebuild DISABLE_SWIFTLINT=1 .* -quiet -project .*-configuration Debug .*-onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation .* CODE_SIGNING_ALLOWED=NO$'
expect_calls 0 'Chromium'
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${macos}.*-scheme Pilot -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${macos}.*-scheme DroneTools -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test .*${macos}.*-scheme PilotTests -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test .*${macos}.*-scheme DroneTests -destination platform=macOS,arch=$(uname -m) "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${simulator}.*-scheme Copilot ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build .*${simulator}.*-scheme Plotter ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build-for-testing .*${simulator}.*-scheme SharedTests ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test-without-building .*${simulator}.*-scheme SharedTests -destination platform=iOS Simulator,id=$IOS_SIMULATOR_UDID "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 build-for-testing .*${simulator}.*-scheme PlotterTests ${generic} "
expect_calls 1 "^xcodebuild DISABLE_SWIFTLINT=1 test-without-building .*${simulator}.*-scheme PlotterTests -destination platform=iOS Simulator,id=$IPAD_SIMULATOR_UDID "
expect_actions 'build Pilot
build DroneTools
build Copilot
build Plotter
test PilotTests
build-for-testing SharedTests
test-without-building SharedTests
build-for-testing PlotterTests
test-without-building PlotterTests
test DroneTests'
expect_calls 0 '^xcrun xcresulttool'

# Standalone suites still build what they need.
reset_log
"$work/apple/bin/test.sh" pilot
expect_calls 1 '^cockpit-ui-boundary$'
expect_calls 1 '^xcodebuild '
expect_calls 1 '^xcodebuild DISABLE_SWIFTLINT=1 test .*-scheme PilotTests '
reset_log
"$work/apple/bin/test.sh" shared
expect_calls 2 '^xcodebuild '
expect_actions 'build-for-testing SharedTests
test-without-building SharedTests'
[[ "$(find "$root/ios-simulator-debug/Build/Products" -name 'SharedTests_*.xctestrun' | wc -l | tr -d ' ')" == 1 ]] ||
  fail "expected one current SharedTests test-run description"
reset_log
"$work/apple/bin/test.sh" plotter
expect_calls 2 '^xcodebuild '
expect_actions 'build-for-testing PlotterTests
test-without-building PlotterTests'
[[ "$(find "$root/ios-simulator-debug/Build/Products" -name 'PlotterTests_*.xctestrun' | wc -l | tr -d ' ')" == 1 ]] ||
  fail "expected one current PlotterTests test-run description"

# A failed build-for-testing never falls through to test-without-building,
# and a stale description from an earlier run is not left to be executed.
reset_log
if CI_TEST_FAIL_ACTION=build-for-testing "$work/apple/bin/test.sh" shared; then
  fail "a failed build-for-testing must fail test.sh"
fi
expect_calls 0 ' test-without-building '
[[ -z "$(find "$root/ios-simulator-debug/Build/Products" -name 'SharedTests_*.xctestrun')" ]] ||
  fail "a stale SharedTests test-run description survived a failed build"

# Failure summaries cover this run's result bundles only.
mkdir -p "$root/macos-debug/Logs/Test/earlier.xcresult"
touch -t 200001010000 "$root/macos-debug/Logs/Test/earlier.xcresult"
reset_log
if CI_TEST_FAIL_ACTION="test" "$work/apple/bin/test.sh" pilot; then
  fail "a failed test run must fail test.sh"
fi
expect_calls 1 '^xcrun xcresulttool get test-results summary --path .*/failed.xcresult$'
expect_calls 0 'earlier.xcresult'
[[ -z "$(find "$root" -maxdepth 1 -name '.test-run.*')" ]] || fail "run marker was not removed"

# Unknown suites are rejected before any build.
reset_log
status=0
"$work/apple/bin/test.sh" bogus 2>/dev/null || status=$?
[[ "$status" == 2 ]] || fail "unknown suite exited $status, expected 2"
expect_calls 0 '^xcodebuild '

# A presentation regression fails before any application or hosted-test build.
reset_log
if CI_TEST_BOUNDARY_FAILURE=1 "$work/apple/bin/build-ci.sh"; then
  fail "a failed Cockpit boundary check must fail build-ci.sh"
fi
expect_calls 1 '^cockpit-ui-boundary$'
expect_calls 0 '^xcodebuild '
expect_calls 0 '^icons '
reset_log
if CI_TEST_BOUNDARY_FAILURE=1 "$work/apple/bin/test.sh" pilot; then
  fail "a failed Cockpit boundary check must fail the hosted Pilot test lane"
fi
expect_calls 1 '^cockpit-ui-boundary$'
expect_calls 0 '^xcodebuild '

# An explicit root relocates both scripts together.
reset_log
BLAU_DERIVED_DATA="$work/custom" "$work/apple/bin/build-ci.sh"
BLAU_DERIVED_DATA="$work/custom" "$work/apple/bin/test.sh" pilot
expect_calls 3 "-derivedDataPath $work/custom/macos-debug "

printf 'Apple CI script orchestration checks passed.\n'
