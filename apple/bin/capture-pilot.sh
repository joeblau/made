#!/usr/bin/env bash
#
# capture-pilot.sh — capture a Pilot (macOS) window screenshot in demo mode.
#
# fastlane snapshot can't drive macOS, so Pilot is captured directly. This
# builds Pilot (Debug), launches the .app with the DEMO-MODE launch arguments
# (["-demoMode", "YES"]) so it renders representative fixture state with no live
# companion peers, waits for the window, then captures the frontmost Pilot
# window.
#
# NOTE: macOS window capture is interactive-ish. You may want to arrange the
# workspace (resize the window, pick panes) before the capture fires — set
# PILOT_CAPTURE_DELAY to add more lead time, or run with INTERACTIVE=1 to be
# prompted to press Return when the layout looks right.
#
# Output: workers/web/public/screenshots/pilot/01-pilot.png
#
# Run from apple/:  ./bin/capture-pilot.sh
set -euo pipefail

usage() {
  echo "Usage: $0 [--dry-run] [--preserve-build]"
  echo "  --dry-run         print the resolved capture plan without building or launching"
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
OUT_DIR="$APPLE_DIR/../workers/web/public/screenshots/pilot"
OUT="$OUT_DIR/01-pilot.png"
mkdir -p "$OUT_DIR"

PROJECT="$APPLE_DIR/made.xcodeproj"
SCHEME="Pilot"
CAPTURE_DELAY="${PILOT_CAPTURE_DELAY:-5}"
DERIVED=""
PILOT_PID=""
TMP_OUT="${OUT%.png}.tmp.$$.png"

cleanup() {
  status=$?
  trap - EXIT INT TERM
  rm -f -- "$TMP_OUT"
  if [ -n "$PILOT_PID" ]; then
    kill "$PILOT_PID" 2>/dev/null || true
    wait "$PILOT_PID" 2>/dev/null || true
  fi
  if [ -n "$DERIVED" ] && [ "$PRESERVE_BUILD" != "1" ]; then
    rm -rf -- "$DERIVED"
  elif [ -n "$DERIVED" ]; then
    echo "    Preserved DerivedData: $DERIVED"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

for tool in xcodebuild xcode-select open osascript screencapture; do
  command -v "$tool" >/dev/null || { echo "ERROR: required tool not found: $tool" >&2; exit 1; }
done

if [ "$DRY_RUN" = "1" ]; then
  echo "Project: $PROJECT"
  echo "Scheme: $SCHEME"
  echo "Output: $OUT"
  echo "Capture delay: ${CAPTURE_DELAY}s"
  exit 0
fi

# Preflight: the Pilot build pulls in CodeEditSourceEditor, whose targets carry a
# transitive SwiftLint build-tool plugin. Xcode runs that plugin's swiftlint in a
# sandbox that strips DEVELOPER_DIR / XCODE_DEFAULT_TOOLCHAIN_OVERRIDE, so swiftlint
# resolves the toolchain via the *global* `xcode-select`. If that points at the
# Command Line Tools (which ship no sourcekitdInProc.framework), swiftlint traps and
# the whole build dies with "Plug-in ended with uncaught signal: 5". Catch it here
# with the exact remedy instead of a cryptic failure 10 minutes into the build.
ACTIVE_DEV="$(xcode-select -p 2>/dev/null || true)"
if [ ! -d "$ACTIVE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitdInProc.framework" ]; then
  XCODE_APP="$(/usr/bin/find /Applications -maxdepth 1 -name 'Xcode*.app' -print -quit 2>/dev/null || true)"
  {
    echo "ERROR: active developer dir has no sourcekitd: ${ACTIVE_DEV:-<unset>}"
    echo "       The SwiftLint build-tool plugin (via CodeEditSourceEditor) will crash"
    echo "       the build with 'Plug-in ended with uncaught signal: 5'."
    if [ -n "$XCODE_APP" ]; then
      echo "       Fix: sudo xcode-select -s \"$XCODE_APP/Contents/Developer\""
    else
      echo "       Fix: install Xcode, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
  } >&2
  exit 1
fi

echo "==> Building $SCHEME (Debug)"
DERIVED="$(mktemp -d -t blau-pilot-capture.XXXXXX)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  build | tail -5

APP_PATH="$(/usr/bin/find "$DERIVED/Build/Products" -name 'made.app' -maxdepth 3 | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "ERROR: built made.app not found under $DERIVED" >&2
  exit 1
fi
echo "    App: $APP_PATH"

echo "==> Launching Pilot in demo mode"
# Launch the built executable directly so cleanup can terminate exactly the
# process created by this script rather than every app named made.
"$APP_PATH/Contents/MacOS/made" -demoMode YES >/dev/null 2>&1 &
PILOT_PID=$!

echo "==> Waiting ${CAPTURE_DELAY}s for the window to appear"
sleep "$CAPTURE_DELAY"

if [ "${INTERACTIVE:-0}" = "1" ]; then
  echo "==> Arrange the Pilot window, then press Return to capture..."
  read -r _
fi

# Find the frontmost Pilot window id via AppleScript, then capture just it.
echo "==> Locating Pilot window"
WINDOW_ID="$(osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
  set procs to (every process whose name is "made")
  if (count of procs) is 0 then return ""
end tell
tell application "made" to activate
OSA
)"

# Prefer a precise window capture; fall back to interactive selection.
PILOT_WIN="$(/usr/bin/python3 - <<'PY' 2>/dev/null || true
import subprocess, json, sys
try:
    import Quartz
except Exception:
    sys.exit(0)
wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
for w in wins:
    if w.get('kCGWindowOwnerName') == 'made' and w.get('kCGWindowLayer', 0) == 0:
        print(w.get('kCGWindowNumber'))
        break
PY
)"

if [ -n "$PILOT_WIN" ]; then
  echo "==> Capturing Pilot window #$PILOT_WIN -> $OUT"
  screencapture -o -l"$PILOT_WIN" "$TMP_OUT"
else
  echo "==> Could not resolve a window id automatically."
  echo "    Falling back to interactive region capture: drag to select the Pilot window."
  screencapture -o -i "$TMP_OUT"
fi

mv -f -- "$TMP_OUT" "$OUT"

echo "==> Done: $OUT"
