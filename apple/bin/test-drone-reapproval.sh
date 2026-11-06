#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-reapproval-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneReapprovalProof \
  -o "$BUILD_DIR/DroneReapprovalProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneSecureChannel.swift" \
  "$APPLE_ROOT/Sources/Shared/DronePairing.swift" \
  "$APPLE_ROOT/Sources/Shared/PeerSyncAuthentication.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/CryptoCore.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/DeviceIdentity.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/NoiseIKHandshake.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/PacketCodec.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/ReplayWindow.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/SecurePairingStore.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneLANTransport.swift" \
  "$APPLE_ROOT/Tests/DroneReapprovalProof/main.swift"

"$BUILD_DIR/DroneReapprovalProof"
