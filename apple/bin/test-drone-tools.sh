#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-tool-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneToolProof \
  -o "$BUILD_DIR/DroneToolProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolClient.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneAgentDriver.swift" \
  "$APPLE_ROOT/Tests/DroneToolProof/DroneToolFakes.swift" \
  "$APPLE_ROOT/Tests/DroneToolProof/main.swift"

"$BUILD_DIR/DroneToolProof"
