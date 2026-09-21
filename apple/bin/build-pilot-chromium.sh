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

"$APPLE_ROOT/bin/update-chromiumkit-artifact.sh"
"$APPLE_ROOT/bin/install-xcodegen.sh" generate \
  --spec "$APPLE_ROOT/project.yml" --project "$APPLE_ROOT"

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
  -destination 'platform=macOS' \
  "$@"
