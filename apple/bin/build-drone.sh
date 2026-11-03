#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
DERIVED_ROOT="${BLAU_DRONE_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-builds/DroneRelease}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"
IDENTITY="${DRONE_CODE_SIGN_IDENTITY:-Apple Development}"
PRODUCTS="$DERIVED_ROOT/Build/Products/Release"
PACKAGE="$DERIVED_ROOT/package"

rm -rf "$PACKAGE"
DISABLE_SWIFTLINT=1 xcodebuild clean build -quiet \
  -project "$PROJECT" \
  -scheme DroneTools \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_ROOT" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES

mkdir -p "$PACKAGE"
for executable in drone droned; do
  architectures="$(lipo -archs "$PRODUCTS/$executable")"
  [[ " $architectures " == *" arm64 "* ]] || { echo "$executable is missing arm64" >&2; exit 1; }
  [[ " $architectures " == *" x86_64 "* ]] || { echo "$executable is missing x86_64" >&2; exit 1; }
  codesign --verify --strict "$PRODUCTS/$executable"
  ditto "$PRODUCTS/$executable" "$PACKAGE/$executable"
  codesign --verify --strict "$PACKAGE/$executable"
done

"$PACKAGE/drone" --version
printf 'Signed universal Drone package: %s\n' "$PACKAGE"
