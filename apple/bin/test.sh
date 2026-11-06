#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/xcodebuild-ci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/xcodebuild-ci.sh"
SUITE="${1:-all}"

case "$SUITE" in
  pilot|shared|plotter|drone|drone-protocol|drone-lifecycle|all) ;;
  *) echo "Usage: apple/bin/test.sh [pilot|shared|plotter|drone|drone-protocol|drone-lifecycle|all]" >&2; exit 2 ;;
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

# Builds Cockpit as the test host incrementally: after build-ci.sh only the test
# bundle compiles.
pilot() {
  ci_xcodebuild test "$MACOS_DERIVED_DATA" \
    -scheme PilotTests \
    -destination "$MACOS_DESTINATION"
}

hosted_test() {
  local scheme="$1"
  local udid="$2"
  # Build the host and tests for the same generic destination as build-ci.sh so
  # the host is reused, then run exactly the products this invocation built.
  # Removing earlier descriptions and stopping on a failed build (set -e) keeps
  # test-without-building from running stale or foreign products.
  rm -f "$IOS_SIMULATOR_DERIVED_DATA"/Build/Products/"${scheme}"_*.xctestrun
  ci_xcodebuild build-for-testing "$IOS_SIMULATOR_DERIVED_DATA" \
    -scheme "$scheme" \
    -destination "$IOS_SIMULATOR_BUILD_DESTINATION"
  ci_xcodebuild test-without-building "$IOS_SIMULATOR_DERIVED_DATA" \
    -scheme "$scheme" \
    -destination "platform=iOS Simulator,id=$udid"
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
  hosted_test SharedTests "$udid"
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
  hosted_test PlotterTests "$udid"
}

drone_lifecycle() {
  ci_xcodebuild test "$MACOS_DERIVED_DATA" \
    -scheme DroneTests \
    -destination "$MACOS_DESTINATION"
  "$APPLE_ROOT/bin/test-drone-launchd.sh"
}

drone_execution() {
  "$APPLE_ROOT/bin/test-drone-revocation.sh"
  "$APPLE_ROOT/bin/test-drone-jobs.sh"
  "$APPLE_ROOT/bin/test-drone-job-tools.sh"
  "$APPLE_ROOT/bin/test-drone-terminal.sh"
  "$APPLE_ROOT/bin/test-drone-tools.sh"
  "$APPLE_ROOT/bin/test-drone-worker.sh"
}

case "$SUITE" in
  pilot) pilot ;;
  shared) shared ;;
  plotter) plotter ;;
  drone-protocol) "$APPLE_ROOT/bin/test-drone-protocol.sh" ;;
  drone-lifecycle) drone_lifecycle ;;
  drone) "$APPLE_ROOT/bin/test-drone-protocol.sh"; drone_lifecycle; drone_execution ;;
  all) pilot; shared; plotter; "$APPLE_ROOT/bin/test-drone-protocol.sh"; drone_lifecycle; drone_execution ;;
esac
