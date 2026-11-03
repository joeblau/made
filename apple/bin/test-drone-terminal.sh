#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
