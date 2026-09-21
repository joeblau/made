#!/usr/bin/env bash
set -euo pipefail

# Builds the Chromium configuration and installs the finished bundle to a stable
# path, so the Chromium-backed Pilot can be launched without digging through a
# hash-named DerivedData directory that a Clean Build Folder erases.
#
# This is a local developer convenience, not a distribution step. It installs a
# development-signed build; shipping to users still goes through the signed,
# notarized release workflow and validate-chromium-archive.sh.

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${BLAU_PILOT_INSTALL_PATH:-/Applications/made.app}"
SKIP_BUILD=0
QUIT_RUNNING=0

fail() {
  printf 'Pilot Chromium install error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: install-pilot-chromium.sh [--skip-build] [--quit-running]' \
    '                                 [--destination <made.app>]' \
    '' \
    'Builds the Chromium configuration and installs it to a stable location.' \
    'Destination defaults to /Applications/made.app and can also be set with' \
    'BLAU_PILOT_INSTALL_PATH.' \
    '' \
    '--quit-running asks a copy already running from the destination to quit' \
    'and waits for it, instead of refusing the install.' >&2
  exit 2
}

# Terminate the app running from the destination bundle so it can be replaced.
# Only ever asks: a workspace app owns unsaved editor and SwiftData state, and
# a forced kill would trade that state for a few seconds of convenience. If the
# app will not go quietly the caller gets the same refusal as before.
quit_running_app() {
  local destination="$1"
  local name
  name="$(basename "$destination")"

  printf 'Asking the running %s to quit\n' "$name"
  # An app showing a modal sheet never acknowledges the quit event, and
  # AppleScript's default is to wait two minutes for a reply it will not get.
  # Bound it so the poll below is what decides the outcome, not osascript.
  osascript \
    -e 'on run argv' \
    -e '  with timeout of 5 seconds' \
    -e '    tell application (item 1 of argv) to quit' \
    -e '  end timeout' \
    -e 'end run' \
    "$destination" >/dev/null 2>&1 || true

  local waited=0
  while pgrep -f "^${destination}/Contents/MacOS/" >/dev/null; do
    if (( waited >= 30 )); then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s quit; installing over it\n' "$name"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --quit-running)
      QUIT_RUNNING=1
      shift
      ;;
    --destination)
      [[ $# -ge 2 ]] || usage
      DESTINATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

case "$DESTINATION" in
  *.app) ;;
  *) fail "destination must end in .app: $DESTINATION" ;;
esac

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  # The pinned runtime requires Xcode 26.x. build-pilot-chromium.sh reads
  # whatever xcode-select points at, which is commonly a newer beta, so select
  # the required toolchain here unless the caller already chose one.
  if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -version 2>/dev/null | grep -Eq '^Xcode 26\.'; then
    for candidate in /Applications/Xcode-26*.app/Contents/Developer; do
      [[ -d "$candidate" ]] || continue
      DEVELOPER_DIR="$candidate"
      export DEVELOPER_DIR
      printf 'Using %s\n' "$DEVELOPER_DIR"
      break
    done
  fi
  "$APPLE_ROOT/bin/build-pilot-chromium.sh"
fi

# Ask the build system where it actually put the product rather than guessing at
# the DerivedData hash.
BUILT_PRODUCTS_DIR="$(
  xcodebuild -project "$APPLE_ROOT/made.xcodeproj" \
    -scheme Pilot \
    -configuration Chromium \
    -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
)"
[[ -n "$BUILT_PRODUCTS_DIR" ]] || fail "could not resolve BUILT_PRODUCTS_DIR"

SOURCE_APP="$BUILT_PRODUCTS_DIR/made.app"
[[ -d "$SOURCE_APP" ]] || fail "no built app at $SOURCE_APP (run without --skip-build)"

# Refuse to install something that would not actually run Chromium: the whole
# point of this configuration is the embedded engine and its helper processes.
[[ -d "$SOURCE_APP/Contents/Frameworks/Chromium Embedded Framework.framework" ]] \
  || fail "built app has no embedded CEF framework — was this the Chromium configuration?"

helper_count="$(find "$SOURCE_APP/Contents/Frameworks" -maxdepth 1 -name '*Helper*.app' | wc -l | tr -d ' ')"
[[ "$helper_count" -ge 1 ]] || fail "built app has no CEF helper bundles"

codesign --verify "$SOURCE_APP" 2>/dev/null \
  || fail "built app fails signature verification; rebuild before installing"

if [[ -e "$DESTINATION" ]]; then
  running_from_destination="$(pgrep -f "^${DESTINATION}/Contents/MacOS/" || true)"
  if [[ -n "$running_from_destination" && "$QUIT_RUNNING" -eq 1 ]]; then
    quit_running_app "$DESTINATION" \
      || fail "$(basename "$DESTINATION") did not quit within 30s — an open dialog or sheet blocks the quit event; dismiss it, quit the app, and retry"
    running_from_destination=""
  fi
  [[ -z "$running_from_destination" ]] \
    || fail "quit the running $(basename "$DESTINATION") before installing over it (or pass --quit-running)"
fi

# Stage beside the destination and swap, so an interrupted copy cannot leave a
# half-written 800 MB bundle where a working app used to be.
staging="$(dirname "$DESTINATION")/.$(basename "$DESTINATION").installing.$$"
previous="$(dirname "$DESTINATION")/.$(basename "$DESTINATION").previous.$$"
cleanup() {
  rm -rf "$staging"
  [[ -e "$previous" ]] && rm -rf "$previous"
  return 0
}
trap cleanup EXIT

rm -rf "$staging"
ditto "$SOURCE_APP" "$staging" || fail "copy to $staging failed"
# ditto preserves directory dates. macOS can then keep an old cached app
# Info.plist, rejecting newly declared Bonjour services even after LSRegisterURL.
# Refresh both bundle directories so an existing installation's metadata expires.
touch "$staging" "$staging/Contents"

if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$previous" || fail "could not move the existing app aside"
fi
if ! mv "$staging" "$DESTINATION"; then
  [[ -e "$previous" ]] && mv "$previous" "$DESTINATION"
  fail "could not move the new app into place"
fi

codesign --verify "$DESTINATION" 2>/dev/null \
  || printf 'Warning: installed app failed signature verification at %s\n' "$DESTINATION" >&2

printf 'Installed Chromium-enabled Pilot at %s\n' "$DESTINATION"
printf 'CEF helpers bundled: %s\n' "$helper_count"
