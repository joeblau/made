#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/xcodebuild-ci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/xcodebuild-ci.sh"
SUITE="${1:-all}"

case "$SUITE" in
  pilot|shared|all) ;;
  *) echo "Usage: apple/bin/test.sh [pilot|shared|all]" >&2; exit 2 ;;
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
  # Build the Copilot host and SharedTests for the same generic destination as
  # build-ci.sh so the host is reused, then run exactly the products that this
  # invocation just built. Removing earlier test-run descriptions and stopping
  # on a failed build (set -e) keeps test-without-building from running stale
  # or foreign products.
  rm -f "$IOS_SIMULATOR_DERIVED_DATA"/Build/Products/SharedTests_*.xctestrun
  ci_xcodebuild build-for-testing "$IOS_SIMULATOR_DERIVED_DATA" \
    -scheme SharedTests \
    -destination "$IOS_SIMULATOR_BUILD_DESTINATION"
  ci_xcodebuild test-without-building "$IOS_SIMULATOR_DERIVED_DATA" \
    -scheme SharedTests \
    -destination "platform=iOS Simulator,id=$udid"
}

case "$SUITE" in
  pilot) pilot ;;
  shared) shared ;;
  all) pilot; shared ;;
esac
