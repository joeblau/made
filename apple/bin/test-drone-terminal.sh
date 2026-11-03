#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The proof drives real tmux sessions. GitHub's macOS runner ships without
# tmux and CI avoids unpinned downloads, so skip loudly there. Keep these
# paths in sync with DroneTmux.locate().
tmux_found=0
for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
  if [[ -x "$candidate" ]]; then
    tmux_found=1
    break
  fi
done
if [[ "$tmux_found" -eq 0 ]]; then
  message="Drone terminal proof skipped: tmux is not installed; remote PTY/tmux coverage did not run"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning title=Drone terminal proof skipped::%s\n' "$message"
  fi
  printf '%s\n' "$message" >&2
  exit 0
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-terminal-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneTerminalProof \
  -o "$BUILD_DIR/DroneTerminalProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTerminal.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTmux.swift" \
  "$APPLE_ROOT/Sources/Shared/DronePTY.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTerminalEngine.swift" \
  "$APPLE_ROOT/Tests/DroneTerminalProof/main.swift"

"$BUILD_DIR/DroneTerminalProof"
