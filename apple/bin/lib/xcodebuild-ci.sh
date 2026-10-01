# shellcheck shell=bash
# Variables defined here are read by the sourcing scripts.
# shellcheck disable=SC2034
# Shared xcodebuild policy for build-ci.sh and test.sh. Source; do not execute.
#
# Both scripts build the artifact-free Debug configuration with signing
# disabled, frozen package versions, and SwiftLint off. They also share one
# derived-data directory per platform, so `build-ci.sh` followed by
# `test.sh all` (the CI lane) compiles each app and test host once: the test
# run reuses the application products and only compiles the test bundles.
# Chromium-configuration and release builds use their own derived data and
# never read these directories.

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
DERIVED_ROOT="${BLAU_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-apple-ci}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"

# Pin the configuration instead of inheriting a scheme action's. A scheme whose
# Run action points at Chromium would otherwise make this artifact-free lane
# build the CEF-backed configuration and fail on a machine without the pinned
# runtime installed — which is every CI runner.
CI_CONFIGURATION=Debug
MACOS_DESTINATION="platform=macOS,arch=$(uname -m)"
MACOS_DERIVED_DATA="$DERIVED_ROOT/macos-debug"
# Applications and test bundles both build for the generic simulator
# destination so they share one set of products; tests then run on a concrete
# simulator without rebuilding.
IOS_SIMULATOR_BUILD_DESTINATION="generic/platform=iOS Simulator"
IOS_SIMULATOR_DERIVED_DATA="$DERIVED_ROOT/ios-simulator-debug"

# ci_xcodebuild <action> <derived-data> [xcodebuild arguments...]
ci_xcodebuild() {
  local action="$1"
  local derived_data="$2"
  shift 2
  DISABLE_SWIFTLINT=1 xcodebuild "$action" -quiet \
    -project "$PROJECT" \
    -configuration "$CI_CONFIGURATION" \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    "$@" \
    CODE_SIGNING_ALLOWED=NO
}
