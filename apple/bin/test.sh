#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
SUITE="${1:-all}"
DERIVED_ROOT="${BLAU_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-tests}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"

# xcodebuild -quiet can omit XCTest assertion details. Preserve its exit
# status while printing the result bundle summary needed to diagnose CI failures.
report_failure() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    while IFS= read -r result; do
      xcrun xcresulttool get test-results summary --path "$result" || true
    done < <(find "$DERIVED_ROOT" -name '*.xcresult' -type d -prune 2>/dev/null)
  fi
  exit "$status"
}
trap report_failure EXIT

pilot() {
  DISABLE_SWIFTLINT=1 xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme PilotTests \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_ROOT/pilot" \
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
    -derivedDataPath "$DERIVED_ROOT/shared" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
}

case "$SUITE" in
  pilot) pilot ;;
  shared) shared ;;
  all) pilot; shared ;;
  *) echo "Usage: apple/bin/test.sh [pilot|shared|all]" >&2; exit 2 ;;
esac
