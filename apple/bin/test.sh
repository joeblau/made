#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
SUITE="${1:-all}"
# The default root and the per-scheme subdirectories below must match
# build-ci.sh so a test run reuses the app products a preceding build
# produced instead of cold-compiling them into a disjoint DerivedData tree.
DERIVED_ROOT="${BLAU_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-builds}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"

case "$SUITE" in
  pilot|shared|plotter|all) ;;
  *) echo "Usage: apple/bin/test.sh [pilot|shared|plotter|all]" >&2; exit 2 ;;
esac

# Result bundles from earlier runs persist in the shared derived data; only
# summarize the ones this invocation produced.
mkdir -p "$DERIVED_ROOT"
RUN_MARKER="$(mktemp "$DERIVED_ROOT/.test-run.XXXXXX")"

# xcodebuild -quiet can omit XCTest assertion details. Preserve its exit
# status while printing the result bundle summary needed to diagnose CI failures.
report_failure() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    while IFS= read -r result; do
      xcrun xcresulttool get test-results summary --path "$result" || true
    done < <(find "$DERIVED_ROOT" -name '*.xcresult' -type d -newer "$RUN_MARKER" -prune 2>/dev/null)
  fi
  rm -f "$RUN_MARKER"
  exit "$status"
}
trap report_failure EXIT

pilot() {
  DISABLE_SWIFTLINT=1 xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme PilotTests \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_ROOT/Pilot" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
}

shared() {
  local udid="${IOS_SIMULATOR_UDID:-}"
  if [[ -z "$udid" ]]; then
    command -v jq >/dev/null || { echo "jq is required to select a simulator." >&2; exit 1; }
    udid="$(xcrun simctl list devices available --json | jq -r '
      [.devices[] | .[] | select(.isAvailable == true and (.name | startswith("iPhone")))]
      | (map(select(.state == "Booted")) + .)
      | first.udid // empty
    ')"
  fi
  [[ -n "$udid" ]] || { echo "No available iPhone simulator; set IOS_SIMULATOR_UDID." >&2; exit 1; }
  DISABLE_SWIFTLINT=1 xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme SharedTests \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED_ROOT/Copilot" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
}

plotter() {
  local udid="${IPAD_SIMULATOR_UDID:-}"
  if [[ -z "$udid" ]]; then
    command -v jq >/dev/null || { echo "jq is required to select a simulator." >&2; exit 1; }
    udid="$(xcrun simctl list devices available --json | jq -r '
      [.devices[] | .[] | select(.isAvailable == true and (.name | startswith("iPad")))]
      | (map(select(.state == "Booted")) + .)
      | first.udid // empty
    ')"
  fi
  [[ -n "$udid" ]] || { echo "No available iPad simulator; set IPAD_SIMULATOR_UDID." >&2; exit 1; }
  DISABLE_SWIFTLINT=1 xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme PlotterTests \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED_ROOT/Plotter" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
}

case "$SUITE" in
  pilot) pilot ;;
  shared) shared ;;
  plotter) plotter ;;
  all) pilot; shared; plotter ;;
esac
