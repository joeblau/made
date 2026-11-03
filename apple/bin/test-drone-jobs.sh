#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-job-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneJobProof \
  -o "$BUILD_DIR/DroneJobProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobModels.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneWorkspace.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobStore.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneProcessRunner.swift" \
  "$APPLE_ROOT/Sources/Drone/JobEngine/DroneJobEngine.swift" \
  "$APPLE_ROOT/Tests/DroneJobProof/main.swift"

"$BUILD_DIR/DroneJobProof"
