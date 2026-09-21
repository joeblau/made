#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
DERIVED_ROOT="${BLAU_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-builds}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"

"$APPLE_ROOT/bin/app-icon-tool.swift" validate

build() {
  local scheme="$1"
  local destination="$2"
  # Pin the configuration instead of inheriting the scheme's Run action. A
  # scheme whose Run action points at Chromium would otherwise make this
  # artifact-free lane build the CEF-backed configuration and fail on a machine
  # without the pinned runtime installed — which is every CI runner.
  DISABLE_SWIFTLINT=1 xcodebuild build -quiet \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_ROOT/$scheme" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
}

build Pilot "platform=macOS,arch=$(uname -m)"
build Copilot "generic/platform=iOS Simulator"
build Plotter "generic/platform=iOS Simulator"
