#!/usr/bin/env bash
#
# capture-wingman.sh — capture a Wingman (watchOS) screenshot in demo mode.
#
# fastlane snapshot is iOS-only, so the watch app is captured directly via
# simctl. This boots a watchOS simulator, builds + installs Wingman, launches
# it with the DEMO-MODE launch arguments (["-demoMode", "YES"]) so it renders
# representative fixture state with no live Pilot peer, waits for the UI to
# settle, then grabs a PNG.
#
# Output: workers/web/public/screenshots/wingman/01-wingman.png
#
# Run from apple/:  ./bin/capture-wingman.sh
set -euo pipefail

usage() {
  echo "Usage: $0 [--dry-run] [--preserve-build]"
  echo "  --dry-run         print the capture plan without changing simulator state"
  echo "  --preserve-build  keep temporary DerivedData for debugging"
}

DRY_RUN="${DRY_RUN:-0}"
PRESERVE_BUILD="${PRESERVE_BUILD:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --preserve-build) PRESERVE_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$APPLE_DIR/../workers/web/public/screenshots/wingman"
OUT="$OUT_DIR/01-wingman.png"
mkdir -p "$OUT_DIR"

# Chosen sim: newest available Apple Watch (watchOS 26.x matches the project's
# watchOS 26.0 deployment target). Override with WINGMAN_SIM if you like.
SIM_NAME="${WINGMAN_SIM:-Apple Watch Series 11 (46mm)}"
SCHEME="Wingman Watch App"
PROJECT="$APPLE_DIR/made.xcodeproj"
BUNDLE_ID="app.blau.copilot.watchkitapp"
DERIVED=""
UDID=""
BOOTED_BY_SCRIPT=0
LAUNCHED_APP=0
TMP_OUT="${OUT%.png}.tmp.$$.png"

cleanup() {
  status=$?
  trap - EXIT INT TERM
  rm -f -- "$TMP_OUT"
  if [ "$LAUNCHED_APP" = "1" ] && [ -n "$UDID" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  if [ "$BOOTED_BY_SCRIPT" = "1" ] && [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi
  if [ -n "$DERIVED" ] && [ "$PRESERVE_BUILD" != "1" ]; then
    rm -rf -- "$DERIVED"
  elif [ -n "$DERIVED" ]; then
    echo "    Preserved DerivedData: $DERIVED"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

for tool in xcrun xcodebuild open screencapture; do
  command -v "$tool" >/dev/null || { echo "ERROR: required tool not found: $tool" >&2; exit 1; }
done

if [ "$DRY_RUN" = "1" ]; then
  echo "Simulator: $SIM_NAME"
  echo "Project: $PROJECT"
  echo "Scheme: $SCHEME"
  echo "Output: $OUT"
  exit 0
fi

echo "==> Resolving simulator: $SIM_NAME"
UDID="$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [ -z "$UDID" ]; then
  echo "ERROR: no available simulator named '$SIM_NAME'." >&2
  echo "Available watch sims:" >&2
  xcrun simctl list devices available | grep -i watch >&2
  exit 1
fi
echo "    UDID: $UDID"

echo "==> Booting simulator"
if ! xcrun simctl list devices | grep -F "$UDID" | grep -q '(Booted)'; then
  xcrun simctl boot "$UDID"
  BOOTED_BY_SCRIPT=1
fi
open -a Simulator
xcrun simctl bootstatus "$UDID" -b

echo "==> Building $SCHEME (Debug)"
DERIVED="$(mktemp -d -t blau-wingman-capture.XXXXXX)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build | tail -5

APP_PATH="$(/usr/bin/find "$DERIVED/Build/Products" -name 'Wingman.app' -maxdepth 3 | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "ERROR: built Wingman.app not found under $DERIVED" >&2
  exit 1
fi
echo "    App: $APP_PATH"

echo "==> Installing + launching in demo mode"
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoMode YES
LAUNCHED_APP=1

echo "==> Waiting for UI to settle"
sleep 6

echo "==> Capturing screenshot -> $OUT"
xcrun simctl io "$UDID" screenshot "$TMP_OUT"
mv -f -- "$TMP_OUT" "$OUT"
echo "==> Done: $OUT"
