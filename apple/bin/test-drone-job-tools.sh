#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-job-tool-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneJobToolProof \
  -o "$BUILD_DIR/DroneJobToolProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobModels.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneWorkspace.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobStore.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneProcessRunner.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobEngine.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobToolEngine.swift" \
  "$APPLE_ROOT/Tests/DroneJobToolProof/main.swift"

"$BUILD_DIR/DroneJobToolProof"
