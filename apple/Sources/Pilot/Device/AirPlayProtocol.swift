import Foundation

/// Private, bounded pipe protocol shared with Packages/AirPlayReceiver/main.cpp.
/// Each message is a big-endian UInt32 length, a kind byte, then its payload.
struct AirPlayPacket: Equatable, Sendable {
    enum Kind: UInt8, Sendable { case ready = 1, pin, video, stopped, heartbeat, peerActivity, discoveryFailure }
    let kind: Kind
    let payload: Data
}

struct AirPlayPacketDecoder {
    static let maximumBodyLength = 8 * 1024 * 1024
    private(set) var buffered = Data()

    enum Failure: Error { case invalidPacket }

    mutating func append(_ bytes: Data) throws -> [AirPlayPacket] {
        guard bytes.count <= 65_536,
              buffered.count + bytes.count <= Self.maximumBodyLength + 65_540 else {
            throw Failure.invalidPacket
        }
        buffered.append(bytes)
        var offset = 0
        var result: [AirPlayPacket] = []
        while buffered.count - offset >= 4 {
            let start = buffered.startIndex + offset
            let length = buffered[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumBodyLength else { throw Failure.invalidPacket }
            guard buffered.count - offset >= length + 4 else { break }
            guard let kind = AirPlayPacket.Kind(rawValue: buffered[start + 4]) else {
                throw Failure.invalidPacket
            }
            let payload = Data(buffered[start + 5..<start + 4 + length])
            switch kind {
            case .discoveryFailure:
                guard payload.count == 4 else { throw Failure.invalidPacket }
            case .pin:
                guard payload.count == 4, payload.allSatisfy({ (48...57).contains($0) }) else {
                    throw Failure.invalidPacket
                }
            case .video:
                guard !payload.isEmpty else { throw Failure.invalidPacket }
            case .ready, .stopped, .heartbeat, .peerActivity:
                guard payload.isEmpty else { throw Failure.invalidPacket }
            }
            result.append(AirPlayPacket(kind: kind, payload: payload))
            guard result.count <= 1024 else { throw Failure.invalidPacket }
            offset += length + 4
        }
        if offset > 0 { buffered.removeFirst(offset) }
        return result
    }

    func finish() throws {
        guard buffered.isEmpty else { throw Failure.invalidPacket }
    }
}

enum AirPlayDiscoveryFailure {
    static func message(for payload: Data) -> String {
        let code = Int32(bitPattern: payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        switch code {
        case -65570:
            return "macOS blocked wireless discovery. Allow made in System Settings > Privacy & Security > Local Network, then try again."
        case -65571, -65555:
            return "macOS rejected made’s wireless service registration. Quit and reopen the latest made app, then try again. (Bonjour \(code))"
        default:
            return "Wireless discovery could not start (Bonjour \(code)). Try again."
        }
    }
}

/// Annex B access units supplied by libairplay, never an arbitrary unbounded stream.
struct AirPlayH264AccessUnit {
    let parameterSets: [Data]
    let sample: Data
    let isKeyframe: Bool

    init(_ bytes: Data) throws {
        guard bytes.count <= AirPlayPacketDecoder.maximumBodyLength else {
            throw AirPlayPacketDecoder.Failure.invalidPacket
        }
        let input = [UInt8](bytes)
        var boundaries: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 2 < input.count {
            if input[index] == 0, input[index + 1] == 0 {
                if input[index + 2] == 1 {
                    guard boundaries.count < 4096 else { throw AirPlayPacketDecoder.Failure.invalidPacket }
                    boundaries.append((index, 3))
                    index += 3
                    continue
                }
                if index + 3 < input.count, input[index + 2] == 0, input[index + 3] == 1 {
                    guard boundaries.count < 4096 else { throw AirPlayPacketDecoder.Failure.invalidPacket }
                    boundaries.append((index, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        guard boundaries.first?.offset == 0, boundaries.count <= 4096 else {
            throw AirPlayPacketDecoder.Failure.invalidPacket
        }
        var sets: [Data] = []
        var output = Data()
        var keyframe = false
        for (position, boundary) in boundaries.enumerated() {
            let start = boundary.offset + boundary.length
            let end = position + 1 < boundaries.count ? boundaries[position + 1].offset : input.count
            guard start < end, input[start] & 0x80 == 0 else {
                throw AirPlayPacketDecoder.Failure.invalidPacket
            }
            let kind = input[start] & 0x1F
            let unit = Data(input[start..<end])
            if kind == 7 || kind == 8 {
                guard unit.count <= 65_536 else { throw AirPlayPacketDecoder.Failure.invalidPacket }
                sets.append(unit)
            } else {
                keyframe = keyframe || kind == 5
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
                output.append(unit)
            }
        }
        parameterSets = sets
        sample = output
        isKeyframe = keyframe
    }
}

/// All deadlines use a monotonic clock. Idle receivers may wait indefinitely;
/// startup, partial messages, pairing and a nonresponsive helper may not.
struct AirPlayWatchdog {
    var started: TimeInterval
    var lastHeartbeat: TimeInterval
    var ready = false
    var partialMessageSince: TimeInterval?
    var pairingSince: TimeInterval?
    var lastPeerActivity: TimeInterval?

    func failure(at now: TimeInterval) -> String? {
        if !ready, now - started > 10 { return "Wireless receiver did not start. Try again." }
        if ready, now - lastHeartbeat > 5 { return "Wireless receiver stopped responding. Try again." }
        if let partialMessageSince, now - partialMessageSince > 5 {
            return "The wireless video stream was interrupted. Connect again."
        }
        if let pairingSince, now - pairingSince > 90 { return "Pairing timed out. Try again for a new code." }
        if let lastPeerActivity, now - lastPeerActivity > 30 {
            return "The device stopped responding. Check Wi-Fi and start Screen Mirroring again."
        }
        return nil
    }
}
