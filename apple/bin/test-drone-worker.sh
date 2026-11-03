#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-worker-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneWorkerProof \
  -o "$BUILD_DIR/DroneWorkerProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneSecureChannel.swift" \
  "$APPLE_ROOT/Sources/Shared/DronePairing.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneLANTransport.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTerminal.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTmux.swift" \
  "$APPLE_ROOT/Sources/Shared/DronePTY.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTerminalEngine.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolClient.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneAgentDriver.swift" \
  "$APPLE_ROOT/Sources/Shared/PeerSyncAuthentication.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/CryptoCore.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/DeviceIdentity.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/NoiseIKHandshake.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/PacketCodec.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/ReplayWindow.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/SecurePairingStore.swift" \
  "$APPLE_ROOT/Sources/DroneSupport/"*.swift \
  "$APPLE_ROOT/Sources/Drone/JobEngine/"*.swift \
  "$APPLE_ROOT/Sources/Droned/DroneWorkerService.swift" \
  "$APPLE_ROOT/Tests/DroneWorkerProof/main.swift"

"$BUILD_DIR/DroneWorkerProof"
