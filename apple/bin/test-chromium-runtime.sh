#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/made.xcodeproj"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
export DISABLE_SWIFTLINT=YES
export BLAU_CHROMIUM_CODESIGN_TIMESTAMP="${BLAU_CHROMIUM_CODESIGN_TIMESTAMP:-NO}"
TEST_CODE_SIGN_IDENTITY="${BLAU_CHROMIUM_TEST_CODE_SIGN_IDENTITY:-Apple Development}"
TEST_DEVELOPMENT_TEAM="${BLAU_CHROMIUM_TEST_DEVELOPMENT_TEAM:-K78G42H4U2}"
TEST_ARCHITECTURE="${BLAU_CHROMIUM_TEST_ARCHITECTURE:-$(uname -m)}"
signing_settings=(
  "CODE_SIGN_IDENTITY=$TEST_CODE_SIGN_IDENTITY"
  "DEVELOPMENT_TEAM=$TEST_DEVELOPMENT_TEAM"
  "CODE_SIGNING_REQUIRED=YES"
)
if [[ "$TEST_CODE_SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  # Xcode's automatic signing accepts Apple Development but rejects an
  # explicit Developer ID identity. Release smoke tests have only the imported
  # Developer ID key, so make that override consistently manual for every
  # target in the hosted test graph.
  signing_settings+=("CODE_SIGN_STYLE=Manual")
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  printf 'Chromium runtime test error: Xcode developer directory not found: %s\n' \
    "$DEVELOPER_DIR" >&2
  exit 1
fi
xcode_version="$(xcodebuild -version)"
if ! grep -Eq '^Xcode 26\.' <<< "$xcode_version"; then
  printf 'Chromium runtime test error: the pinned runtime requires Xcode 26.x\n' \
    >&2
  exit 1
fi
case "$TEST_ARCHITECTURE" in
  arm64|x86_64) ;;
  *)
    printf 'Chromium runtime test error: unsupported architecture: %s\n' \
      "$TEST_ARCHITECTURE" >&2
    exit 1
    ;;
esac

RESULT_ROOT="${BLAU_CHROMIUM_TEST_RESULT_ROOT:-$(mktemp -d -t chromium-runtime-gate)}"
RESULT_BUNDLE="$RESULT_ROOT/ChromiumRuntimeGate-$TEST_ARCHITECTURE.xcresult"
mkdir -p "$RESULT_ROOT"
rm -rf "$RESULT_BUNDLE"

# DEBUG_INFORMATION_FORMAT=dwarf: the gate has no use for dSYMs, and
# skipping them silences dsymutil warnings from the prebuilt tree-sitter
# archives in CodeEditLanguages, whose DWARF references object files on the
# upstream author's machine.
status=0
xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme PilotTests \
  -configuration Chromium \
  -destination "platform=macOS,arch=$TEST_ARCHITECTURE" \
  -only-testing:PilotTests/ChromiumRealEngineSmokeTests \
  -skipPackagePluginValidation \
  -resultBundlePath "$RESULT_BUNDLE" \
  ENABLE_TESTABILITY=YES \
  DEBUG_INFORMATION_FORMAT=dwarf \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
  ARCHS="$TEST_ARCHITECTURE" \
  ONLY_ACTIVE_ARCH=YES \
  "${signing_settings[@]}" \
  test || status=$?

# -quiet suppresses per-test failure output, so surface the recorded issues
# from the result bundle; without this a CI failure is undiagnosable.
if [[ $status -ne 0 && -d "$RESULT_BUNDLE" ]]; then
  printf 'Chromium runtime gate failures (result bundle: %s):\n' \
    "$RESULT_BUNDLE" >&2
  xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" 2>/dev/null \
    | jq -r '.. | objects | select(.nodeType? == "Failure") | "- " + .name' \
    >&2 || true
fi
exit "$status"
