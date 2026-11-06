#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drone-session-proof.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -module-name DroneSessionProof \
  -o "$BUILD_DIR/DroneSessionProof" \
  "$APPLE_ROOT/Sources/Shared/DroneProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneSecureChannel.swift" \
  "$APPLE_ROOT/Sources/Shared/DronePairing.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneLANTransport.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneTerminal.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolProtocol.swift" \
  "$APPLE_ROOT/Sources/Shared/PeerSyncAuthentication.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/CryptoCore.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/DeviceIdentity.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/NoiseIKHandshake.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/PacketCodec.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/ReplayWindow.swift" \
  "$APPLE_ROOT/Sources/Shared/SecureChannel/SecurePairingStore.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneModels.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneTransport.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneWorkerSupervisor.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneLANTransportFactory.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneDiscovery.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneRegistryPersistence.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneStore.swift" \
  "$APPLE_ROOT/Sources/Pilot/Drones/DroneRemoteTerminalClient.swift" \
  "$APPLE_ROOT/Sources/Pilot/TerminalSession.swift" \
  "$APPLE_ROOT/Sources/Pilot/TerminalRuntimeCache.swift" \
  "$APPLE_ROOT/Sources/Shared/DroneToolClient.swift" \
  "$APPLE_ROOT/Tests/DroneSessionProof/HostFixtures.swift" \
  "$APPLE_ROOT/Tests/DroneSessionProof/main.swift"

"$BUILD_DIR/DroneSessionProof"
