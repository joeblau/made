#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$APPLE_ROOT/.." && pwd)"

for tool in xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Chromium build error: missing required tool: %s\n' "$tool" >&2
    exit 1
  }
done
selected_xcode="$(xcodebuild -version)"
grep -Eq '^Xcode 26\.' <<<"$selected_xcode" || {
  printf 'Chromium build error: the pinned runtime requires Xcode 26.x\n' >&2
  exit 1
}

# The installer reproduces both CEF slices and recompresses the entire runtime.
# Reuse the installed artifact only after checking its lock, receipt and hashes.
if ! "$APPLE_ROOT/bin/verify-installed-chromiumkit.sh"; then
  "$APPLE_ROOT/bin/update-chromiumkit-artifact.sh"
fi
"$APPLE_ROOT/bin/install-xcodegen.sh" generate \
  --use-cache --spec "$APPLE_ROOT/project.yml" --project "$APPLE_ROOT"

local_settings=()
if [[ "${1:-}" == --local ]]; then
  shift
  # Keep development intermediates separate from optimized universal archives.
  # Retain the Chromium configuration, stable signing identity and entitlements.
  local_settings=(
    -derivedDataPath "${BLAU_PILOT_DERIVED_DATA:-$APPLE_ROOT/.build/cockpit}"
    "ARCHS=$(uname -m)" ONLY_ACTIVE_ARCH=YES
    # This command-line setting reaches SwiftPM dependencies too. Unoptimized
    # RoyalVNCKit/CryptoSwift DH authentication can exceed the VNC deadline.
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=incremental
    GCC_OPTIMIZATION_LEVEL=0 DEBUG_INFORMATION_FORMAT=dwarf
    BLAU_CHROMIUM_CODESIGN_TIMESTAMP=NO
  )
fi

# SwiftLintPlugin 0.63.1 declares an Output directory but does not create it.
# Xcode 26 treats the missing prebuild output as a hard failure after linting
# succeeds. Repository lint/test gates run separately, so skip those dependency
# plug-ins only for this pinned Xcode 26 Chromium build.
export DISABLE_SWIFTLINT=YES
cd "$REPOSITORY_ROOT"
exec xcodebuild \
  -project "$APPLE_ROOT/made.xcodeproj" \
  -scheme Pilot \
  -configuration Chromium \
  -destination "platform=macOS,arch=$(uname -m)" \
  -onlyUsePackageVersionsFromResolvedFile \
  ${local_settings[@]+"${local_settings[@]}"} \
  "$@"
