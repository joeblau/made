#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/xcodebuild-ci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/xcodebuild-ci.sh"

"$APPLE_ROOT/bin/app-icon-tool.swift" validate

build() {
  local scheme="$1"
  local destination="$2"
  local derived_data="$3"
  ci_xcodebuild build "$derived_data" \
    -scheme "$scheme" \
    -destination "$destination"
}

build Pilot "$MACOS_DESTINATION" "$MACOS_DERIVED_DATA"
# Copilot embeds the Wingman watch app; Plotter embeds its widget extension.
build Copilot "$IOS_SIMULATOR_BUILD_DESTINATION" "$IOS_SIMULATOR_DERIVED_DATA"
build Plotter "$IOS_SIMULATOR_BUILD_DESTINATION" "$IOS_SIMULATOR_DERIVED_DATA"
