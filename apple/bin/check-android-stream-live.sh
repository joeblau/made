#!/usr/bin/env bash
# Live Android mirror recording continuity and recovery check (GitHub issue #265).
#
# Usage: apple/bin/check-android-stream-live.sh [--typecheck] [serial]
#
# Needs a real, unlocked Android device on adb. Compiles Cockpit's own
# AndroidScreenStream, H264AnnexBAssembler, AndroidStreamRecorder,
# AndroidStreamPolicy, and AdbBridge into a small harness, records across an
# in-place restart and a device-side screenrecord kill, then decodes every
# frame of the recording (see apple/Tools/AndroidStreamLiveCheck/main.swift).
# The harness opens Settings and scrolls it for motion, then presses Back.
# `--typecheck` only typechecks the harness; CI runs it so the tool keeps
# compiling against the sources it drives.
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PILOT="$APPLE_ROOT/Sources/Pilot"
SOURCES=(
  "$APPLE_ROOT/Tools/AndroidStreamLiveCheck/main.swift"
  "$PILOT/Android/AndroidScreenStream.swift"
  "$PILOT/Android/H264AnnexBAssembler.swift"
  "$PILOT/Android/AndroidStreamRecorder.swift"
  "$PILOT/Android/AndroidStreamPolicy.swift"
  "$PILOT/Android/AdbBridge.swift"
  "$PILOT/Android/EmulatorBridge.swift"
  "$PILOT/ProcessRunner.swift"
  "$APPLE_ROOT/Sources/Shared/EncodedVideoSample.swift"
)

if [[ "${1:-}" == "--typecheck" ]]; then
  exec xcrun swiftc -typecheck -parse-as-library -swift-version 6 "${SOURCES[@]}"
fi

ADB="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
[[ -x "$ADB" ]] || { echo "adb not found; set ADB=/path/to/adb" >&2; exit 1; }
SERIAL="${1:-}"
if [[ -z "$SERIAL" ]]; then
  # The first physical device: emulators are not the live gate.
  SERIAL="$("$ADB" devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1; exit }')"
fi
[[ -n "$SERIAL" ]] || { echo "No physical Android device on adb" >&2; exit 1; }

workdir="$(mktemp -d -t blau-android-live.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
xcrun swiftc -O -parse-as-library -swift-version 6 "${SOURCES[@]}" -o "$workdir/android-stream-live-check"
"$workdir/android-stream-live-check" "$ADB" "$SERIAL" "$workdir/recording"
