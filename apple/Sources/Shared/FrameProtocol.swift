import Foundation

/// Pure, socket-free value layer for the HEVC mirroring link.
///
/// Nothing in this file touches `Network.framework`; it is a deterministic
/// value/codec layer so the wire format can be unit
/// tested on any platform. ``FrameLink`` (which *does* own the sockets) builds
/// on top of these types.
///
/// Wire model: every packet serialises to a single `Data` blob whose first byte
/// is a ``FrameProtocol/Kind`` tag. ``FrameLink`` wraps each blob in its
/// 4-byte big-endian length prefix after authenticated encryption on the sole
/// supported production transport: TCP.
public enum FrameProtocol {
    /// Application-level resource ceilings. These are deliberately well above
    /// normal HEVC traffic, but low enough that one hostile LAN peer cannot
    /// force multi-gigabyte allocations from a 32-bit wire length.
    public static let maxVideoDimension = 8_192
    public static let maxParameterSetBytes = 64 * 1_024
    public static let maxSampleBytes = 32 * 1_024 * 1_024
    public static let maxJPEGBytes = 16 * 1_024 * 1_024
    public static let maxAnnotationBytes = 1 * 1_024 * 1_024
    public static let maxDashboardBytes = 512 * 1_024

    // MARK: - Models

    /// Chroma subsampling negotiated for the HEVC stream. `yuv444` keeps text
    /// and terminal output crisp; `yuv420` is the universally safe fallback.
    public enum VideoChroma: UInt8, Sendable, Codable, Equatable {
        case yuv420 = 0
        case yuv444 = 1
    }

    /// HEVC stream configuration. Generalises the old H.264 configuration which
    /// only carried SPS/PPS; HEVC adds a VPS parameter set.
    public struct VideoConfiguration: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let chroma: VideoChroma
        public let vps: Data
        public let sps: Data
        public let pps: Data

        public init(width: Int, height: Int, chroma: VideoChroma, vps: Data, sps: Data, pps: Data) {
            self.width = width
            self.height = height
            self.chroma = chroma
            self.vps = vps
            self.sps = sps
            self.pps = pps
        }
    }

    /// A single compressed HEVC access unit.
    ///
    /// `frameID` increases monotonically across the whole stream so the
    /// receiver can detect loss or reconnect gaps.
    public struct VideoSample: Sendable, Equatable {
        public let frameID: UInt32
        public let isKeyFrame: Bool
        public let data: Data

        public init(frameID: UInt32, isKeyFrame: Bool, data: Data) {
            self.frameID = frameID
            self.isKeyFrame = isKeyFrame
            self.data = data
        }
    }

    /// Receiver -> sender link-quality report used to drive adaptive bitrate.
    public struct LinkFeedback: Sendable, Equatable {
        public let lossPct: Double
        public let rttMs: Double
        public let queueDepth: Int

        public init(lossPct: Double, rttMs: Double, queueDepth: Int) {
            self.lossPct = lossPct
            self.rttMs = rttMs
            self.queueDepth = queueDepth
        }
    }

    /// Decoder capability advertised by the receiver during the handshake.
    public struct Capability: Sendable, Equatable {
        public let supports444: Bool

        public init(supports444: Bool) {
            self.supports444 = supports444
        }
    }

    /// Sender-side transport pressure sampled from the real per-client queue.
    /// The encoder uses this alongside receiver loss/decode feedback to adapt
    /// both bitrate and frame cadence before latency can accumulate.
    public struct TransportMetrics: Sendable, Equatable {
        public let queuedFrames: Int
        public let queuedBytes: Int
        public let droppedFrames: Int
        public let sendLatencyMs: Double
        public let rttMs: Double

        public init(
            queuedFrames: Int,
            queuedBytes: Int,
            droppedFrames: Int,
            sendLatencyMs: Double,
            rttMs: Double
        ) {
            self.queuedFrames = queuedFrames
            self.queuedBytes = queuedBytes
            self.droppedFrames = droppedFrames
            self.sendLatencyMs = sendLatencyMs
            self.rttMs = rttMs
        }
    }

    /// Every logical message that can travel over the authenticated TCP link.
    public enum Packet: Sendable, Equatable {
        /// HEVC parameter sets + geometry. Always sent over TCP.
        case configuration(VideoConfiguration)
        /// A compressed access unit.
        case sample(VideoSample)
        /// Receiver -> sender: please emit an IDR/keyframe now.
        case keyframeRequest
        /// Receiver -> sender: current link quality.
        case linkFeedback(LinkFeedback)
        /// Receiver -> sender: decode capabilities (handshake).
        case capability(Capability)
        /// Client (Plotter) -> sender annotation update, sequence-tagged.
        case annotation(seq: UInt32, message: AnnotationMessage)
        /// Sender -> client acknowledgement of an accepted annotation.
        case annotationAck(seq: UInt32)
        /// Sender -> client: Pilot's current appearance, so a connected Plotter
        /// can match the Mac's light/dark mode instead of its own.
        case appearance(isDark: Bool)
        /// Sender-to-receiver liveness/RTT probe. The receiver immediately
        /// returns the nonce in ``pong`` over the authenticated stream.
        case ping(UInt64)
        case pong(UInt64)
        case dashboard(DashboardSnapshotEnvelope)
        /// Legacy JPEG frame. Decoded for backward compatibility only.
        case jpeg(Data)
    }

    // MARK: - Packet wire tags

    enum Kind: UInt8 {
        case configuration = 1
        case sample = 2
        case keyframeRequest = 3
        case linkFeedback = 4
        case capability = 5
        case annotation = 6
        case annotationAck = 7
        case appearance = 8
        case ping = 9
        case pong = 10
        case dashboard = 11
        // Note: there is no tag for jpeg. A tagless / unknown-tag payload is
        // treated as a legacy raw JPEG by ``decode(_:)``.
    }

    // MARK: - Packet encode / decode

    /// Serialises a packet to a single tagged `Data` blob (no length prefix).
    public static func encode(_ packet: Packet) -> Data {
        switch packet {
        case .configuration(let config):
            guard validConfiguration(config),
                  let width = UInt32(exactly: config.width),
                  let height = UInt32(exactly: config.height),
                  let vpsCount = UInt32(exactly: config.vps.count),
                  let spsCount = UInt32(exactly: config.sps.count),
                  let ppsCount = UInt32(exactly: config.pps.count) else { return Data() }
            var payload = Data()
            payload.append(Kind.configuration.rawValue)
            payload.append(config.chroma.rawValue)
            appendUInt32(width, to: &payload)
            appendUInt32(height, to: &payload)
            appendUInt32(vpsCount, to: &payload)
            appendUInt32(spsCount, to: &payload)
            appendUInt32(ppsCount, to: &payload)
            payload.append(config.vps)
            payload.append(config.sps)
            payload.append(config.pps)
            return payload
        case .sample(let sample):
            guard sample.data.count <= maxSampleBytes else { return Data() }
            var payload = Data()
            payload.append(Kind.sample.rawValue)
            payload.append(sample.isKeyFrame ? 0x1 : 0x0)
            appendUInt32(sample.frameID, to: &payload)
            payload.append(sample.data)
            return payload
        case .keyframeRequest:
            return Data([Kind.keyframeRequest.rawValue])
        case .linkFeedback(let feedback):
            guard feedback.lossPct.isFinite, (0...100).contains(feedback.lossPct),
                  feedback.rttMs.isFinite, (0...60_000).contains(feedback.rttMs),
                  (0...1_000_000).contains(feedback.queueDepth),
                  let queueDepth = UInt32(exactly: feedback.queueDepth) else { return Data() }
            var payload = Data()
            payload.append(Kind.linkFeedback.rawValue)
            appendUInt64(feedback.lossPct.bitPattern, to: &payload)
            appendUInt64(feedback.rttMs.bitPattern, to: &payload)
            appendUInt32(queueDepth, to: &payload)
            return payload
        case .capability(let capability):
            var payload = Data()
            payload.append(Kind.capability.rawValue)
            payload.append(capability.supports444 ? 0x1 : 0x0)
            return payload
        case .annotation(let seq, let message):
            guard validAnnotation(message),
                  let encoded = try? JSONEncoder().encode(message),
                  encoded.count <= maxAnnotationBytes else { return Data() }
            var payload = Data()
            payload.append(Kind.annotation.rawValue)
            appendUInt32(seq, to: &payload)
            payload.append(encoded)
            return payload
        case .annotationAck(let seq):
            var payload = Data()
            payload.append(Kind.annotationAck.rawValue)
            appendUInt32(seq, to: &payload)
            return payload
        case .appearance(let isDark):
            return Data([Kind.appearance.rawValue, isDark ? 0x1 : 0x0])
        case .ping(let nonce):
            var payload = Data([Kind.ping.rawValue])
            appendUInt64(nonce, to: &payload)
            return payload
        case .pong(let nonce):
            var payload = Data([Kind.pong.rawValue])
            appendUInt64(nonce, to: &payload)
            return payload
        case .dashboard(let envelope):
            guard let encoded = try? JSONEncoder().encode(envelope),
                  encoded.count <= maxDashboardBytes else { return Data() }
            var payload = Data([Kind.dashboard.rawValue])
            payload.append(encoded)
            return payload
        case .jpeg(let jpeg):
            return jpeg.count <= maxJPEGBytes ? jpeg : Data()
        }
    }

    /// Parses a tagged `Data` blob back into a ``Packet``. Returns `nil` only
    /// when the payload is empty or structurally invalid for its tag. An
    /// unrecognised first byte is interpreted as a legacy raw JPEG so older
    /// Pilot builds keep working.
    public static func decode(_ payload: Data) -> Packet? {
        guard let first = payload.first,
              payload.count <= maxSampleBytes + 6 else { return nil }
        guard let kind = Kind(rawValue: first) else {
            return payload.count <= maxJPEGBytes ? .jpeg(payload) : nil
        }

        switch kind {
        case .configuration:
            // tag(1) + chroma(1) + width(4) + height(4) + vps(4) + sps(4) + pps(4) = 22
            guard payload.count >= 22 else { return nil }
            guard let chroma = VideoChroma(rawValue: payload[payload.startIndex + 1]) else { return nil }
            let width = Int(readUInt32(from: payload, offset: 2))
            let height = Int(readUInt32(from: payload, offset: 6))
            let vpsLength = Int(readUInt32(from: payload, offset: 10))
            let spsLength = Int(readUInt32(from: payload, offset: 14))
            let ppsLength = Int(readUInt32(from: payload, offset: 18))
            let vpsStart = 22
            guard let spsStart = checkedAdd(vpsStart, vpsLength),
                  let ppsStart = checkedAdd(spsStart, spsLength),
                  let end = checkedAdd(ppsStart, ppsLength),
                  (1...maxVideoDimension).contains(width),
                  (1...maxVideoDimension).contains(height),
                  (1...maxParameterSetBytes).contains(vpsLength),
                  (1...maxParameterSetBytes).contains(spsLength),
                  (1...maxParameterSetBytes).contains(ppsLength),
                  end == payload.count else { return nil }
            return .configuration(VideoConfiguration(
                width: width,
                height: height,
                chroma: chroma,
                vps: slice(payload, vpsStart, spsStart),
                sps: slice(payload, spsStart, ppsStart),
                pps: slice(payload, ppsStart, end)
            ))
        case .sample:
            // tag(1) + flags(1) + frameID(4) = 6
            guard (6...(maxSampleBytes + 6)).contains(payload.count) else { return nil }
            let flags = payload[payload.startIndex + 1]
            let frameID = readUInt32(from: payload, offset: 2)
            return .sample(VideoSample(
                frameID: frameID,
                isKeyFrame: (flags & 0x1) != 0,
                data: slice(payload, 6, payload.count)
            ))
        case .keyframeRequest:
            return payload.count == 1 ? .keyframeRequest : nil
        case .linkFeedback:
            // tag(1) + loss(8) + rtt(8) + queue(4) = 21
            guard payload.count == 21 else { return nil }
            let loss = Double(bitPattern: readUInt64(from: payload, offset: 1))
            let rtt = Double(bitPattern: readUInt64(from: payload, offset: 9))
            let queue = Int(readUInt32(from: payload, offset: 17))
            guard loss.isFinite, (0...100).contains(loss),
                  rtt.isFinite, (0...60_000).contains(rtt),
                  queue <= 1_000_000 else { return nil }
            return .linkFeedback(LinkFeedback(lossPct: loss, rttMs: rtt, queueDepth: queue))
        case .capability:
            guard payload.count == 2, payload[payload.startIndex + 1] <= 1 else { return nil }
            return .capability(Capability(supports444: payload[payload.startIndex + 1] != 0))
        case .annotation:
            guard (6...(maxAnnotationBytes + 5)).contains(payload.count) else { return nil }
            let seq = readUInt32(from: payload, offset: 1)
            guard let message = try? JSONDecoder().decode(
                AnnotationMessage.self,
                from: slice(payload, 5, payload.count)
            ), validAnnotation(message) else { return nil }
            return .annotation(seq: seq, message: message)
        case .annotationAck:
            guard payload.count == 5 else { return nil }
            return .annotationAck(seq: readUInt32(from: payload, offset: 1))
        case .appearance:
            guard payload.count == 2, payload[payload.startIndex + 1] <= 1 else { return nil }
            return .appearance(isDark: payload[payload.startIndex + 1] != 0)
        case .ping:
            return payload.count == 9 ? .ping(readUInt64(from: payload, offset: 1)) : nil
        case .pong:
            return payload.count == 9 ? .pong(readUInt64(from: payload, offset: 1)) : nil
        case .dashboard:
            guard (2...(maxDashboardBytes + 1)).contains(payload.count),
                  let envelope = try? JSONDecoder().decode(
                    DashboardSnapshotEnvelope.self,
                    from: slice(payload, 1, payload.count)
                  ) else { return nil }
            return .dashboard(envelope)
        }
    }

    // MARK: - Byte helpers

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private static func validConfiguration(_ config: VideoConfiguration) -> Bool {
        (1...maxVideoDimension).contains(config.width)
            && (1...maxVideoDimension).contains(config.height)
            && (1...maxParameterSetBytes).contains(config.vps.count)
            && (1...maxParameterSetBytes).contains(config.sps.count)
            && (1...maxParameterSetBytes).contains(config.pps.count)
    }

    private static func validAnnotation(_ message: AnnotationMessage) -> Bool {
        let strokes: [AnnotationStroke]
        switch message {
        case .replaceDrawing(let drawing):
            strokes = drawing.strokes
        case .addStroke(let stroke):
            strokes = [stroke]
        case .clear, .undo:
            return true
        }
        guard strokes.count <= 4_096 else { return false }
        var pointCount = 0
        for stroke in strokes {
            guard stroke.width.isFinite, (0.1...256).contains(stroke.width),
                  [stroke.color.red, stroke.color.green, stroke.color.blue, stroke.color.alpha]
                    .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
            let (newCount, overflow) = pointCount.addingReportingOverflow(stroke.points.count)
            guard !overflow, newCount <= 100_000,
                  stroke.points.allSatisfy({ point in
                      point.x.isFinite && point.y.isFinite
                          && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
                  }) else { return false }
            pointCount = newCount
        }
        return true
    }

    private static func slice(_ data: Data, _ start: Int, _ end: Int) -> Data {
        data.subdata(in: (data.startIndex + start) ..< (data.startIndex + end))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.dropFirst(offset).prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}

/// A tiny, deterministic admission controller for asynchronous work. At most
/// `maximumInFlight` elements may be processing; when saturated, only the
/// newest pending element is retained. It is generic so VideoToolbox's pixel
/// buffers can use it in production while integer fixtures prove the bound.
struct LatestWorkCoalescer<Element> {
    let maximumInFlight: Int
    private(set) var inFlight = 0
    private(set) var pending: Element?
    private(set) var dropped = 0

    init(maximumInFlight: Int) {
        self.maximumInFlight = max(1, maximumInFlight)
    }

    mutating func offer(_ element: Element) -> Element? {
        guard inFlight < maximumInFlight else {
            if pending != nil { dropped += 1 }
            pending = element
            return nil
        }
        inFlight += 1
        return element
    }

    mutating func complete() -> Element? {
        if inFlight > 0 { inFlight -= 1 }
        guard inFlight < maximumInFlight, let next = pending else { return nil }
        pending = nil
        inFlight += 1
        return next
    }
}

/// Bounded, stale-frame-aware queue used independently by every FrameLink
/// client. Configuration and keyframes displace obsolete delta frames so a
/// lagging client can recover; delta saturation always keeps the newest frame.
struct FrameSendQueue {
    enum Kind: Equatable {
        case configuration
        case keyFrame
        case deltaFrame
        case control

        var isFrame: Bool {
            self == .keyFrame || self == .deltaFrame
        }
    }

    struct Item: Equatable {
        let payload: Data
        let kind: Kind
        let enqueuedAt: TimeInterval
    }

    let maximumFrames: Int
    let maximumBytes: Int
    let maximumItems: Int
    private(set) var items: [Item] = []
    private(set) var queuedBytes = 0
    private(set) var droppedFrames = 0

    var queuedFrames: Int { items.count(where: { $0.kind.isFrame }) }

    init(
        maximumFrames: Int = 4,
        maximumBytes: Int = 40 * 1_024 * 1_024,
        maximumItems: Int = 64
    ) {
        self.maximumFrames = max(1, maximumFrames)
        self.maximumBytes = max(1, maximumBytes)
        self.maximumItems = max(1, maximumItems)
    }

    /// Returns false only when a non-droppable packet cannot fit. Callers
    /// disconnect that persistently unhealthy client instead of growing memory.
    @discardableResult
    mutating func enqueue(_ payload: Data, kind: Kind, now: TimeInterval) -> Bool {
        guard !payload.isEmpty, payload.count <= maximumBytes else {
            if kind.isFrame { droppedFrames += 1 }
            return kind == .deltaFrame
        }

        switch kind {
        case .configuration:
            removeAll(where: { $0.kind == .configuration })
        case .keyFrame:
            removeAll(where: { $0.kind == .deltaFrame || $0.kind == .keyFrame })
        case .deltaFrame, .control:
            break
        }

        while wouldExceedBudget(adding: payload.count, kind: kind),
              let stale = items.firstIndex(where: { $0.kind == .deltaFrame }) {
            remove(at: stale, countedAsDrop: true)
        }

        guard !wouldExceedBudget(adding: payload.count, kind: kind) else {
            if kind.isFrame { droppedFrames += 1 }
            // Dropping a fresh delta is expected under pressure. Configuration,
            // keyframes, and control messages are recovery-critical.
            return kind == .deltaFrame
        }

        items.append(Item(payload: payload, kind: kind, enqueuedAt: now))
        queuedBytes += payload.count
        return true
    }

    mutating func dequeue() -> Item? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        queuedBytes -= item.payload.count
        return item
    }

    mutating func removeAll() {
        items.removeAll(keepingCapacity: true)
        queuedBytes = 0
    }

    private func wouldExceedBudget(adding bytes: Int, kind: Kind) -> Bool {
        queuedBytes > maximumBytes - bytes
            || items.count >= maximumItems
            || (kind.isFrame && queuedFrames >= maximumFrames)
    }

    private mutating func removeAll(where shouldRemove: (Item) -> Bool) {
        for index in items.indices.reversed() where shouldRemove(items[index]) {
            remove(at: index, countedAsDrop: items[index].kind.isFrame)
        }
    }

    private mutating func remove(at index: Int, countedAsDrop: Bool) {
        let item = items.remove(at: index)
        queuedBytes -= item.payload.count
        if countedAsDrop { droppedFrames += 1 }
    }
}
