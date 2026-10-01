import Foundation
import Testing
@testable import Pilot

/// The assembler parses bytes an untrusted device controls, so these tests are
/// the load-bearing security checks: every allocation bound, plus the framing
/// behaviors the mirror depends on (chunk-split start codes, byte-identical
/// parameter-set dedupe, IDR flagging, trailing-frame flush).
@Suite("H264 Annex-B assembler")
struct H264AnnexBAssemblerTests {
    private let startCode4 = Data([0, 0, 0, 1])
    private let startCode3 = Data([0, 0, 1])
    /// Minimal plausible parameter sets (NAL header + payload bytes).
    private let sps = Data([0x67, 0x42, 0xC0, 0x32, 0x8D, 0x68])
    private let pps = Data([0x68, 0xCE, 0x01, 0xA8])
    /// IDR (type 5) and non-IDR (type 1) slices with first_mb_in_slice == 0
    /// (first payload bit set).
    private let idrSlice = Data([0x65, 0xB8, 0x00, 0x04])
    private let pSlice = Data([0x41, 0x9A, 0x00, 0x04])

    private func stream(_ nalus: [Data]) -> Data {
        var data = Data()
        for nalu in nalus {
            data.append(startCode4)
            data.append(nalu)
        }
        return data
    }

    @Test
    func parsesParameterSetsAndAccessUnits() throws {
        var assembler = H264AnnexBAssembler()
        var events = try assembler.feed(stream([sps, pps, idrSlice, pSlice]))
        events += try assembler.flushTrailing()

        #expect(events.count == 3)
        #expect(events[0] == .parameterSets(sps: sps, pps: pps))
        guard case .accessUnit(let idrData, let isIDR) = events[1] else {
            Issue.record("expected access unit"); return
        }
        #expect(isIDR)
        // AVCC framing: 4-byte big-endian length prefix.
        #expect(idrData.prefix(4) == Data([0, 0, 0, UInt8(idrSlice.count)]))
        #expect(idrData.dropFirst(4) == idrSlice)
        guard case .accessUnit(_, let secondIsIDR) = events[2] else {
            Issue.record("expected access unit"); return
        }
        #expect(!secondIsIDR)
    }

    @Test
    func toleratesStartCodesSplitAcrossChunks() throws {
        var assembler = H264AnnexBAssembler()
        let full = stream([sps, pps, idrSlice, pSlice])
        var events: [H264AnnexBAssembler.Event] = []
        // Feed one byte at a time — worst-case chunk boundaries.
        for byte in full {
            events += try assembler.feed(Data([byte]))
        }
        events += try assembler.flushTrailing()
        #expect(events.count == 3)
        #expect(events[0] == .parameterSets(sps: sps, pps: pps))
    }

    @Test
    func supportsThreeByteStartCodes() throws {
        var assembler = H264AnnexBAssembler()
        var data = Data()
        for nalu in [sps, pps, idrSlice] {
            data.append(startCode3)
            data.append(nalu)
        }
        var events = try assembler.feed(data)
        events += try assembler.flushTrailing()
        #expect(events.count == 2)
    }

    @Test
    func ignoresByteIdenticalParameterSetResends() throws {
        var assembler = H264AnnexBAssembler()
        var events = try assembler.feed(stream([sps, pps, idrSlice]))
        events += try assembler.flushTrailing()
        // A screenrecord respawn re-sends the same SPS/PPS.
        var second = try assembler.feed(stream([sps, pps, idrSlice]))
        second += try assembler.flushTrailing()
        #expect(second.allSatisfy { event in
            if case .parameterSets = event { return false }
            return true
        })
    }

    @Test
    func emitsNewParameterSetsWhenTheyChange() throws {
        var assembler = H264AnnexBAssembler()
        _ = try assembler.feed(stream([sps, pps, idrSlice]))
        _ = try assembler.flushTrailing()
        var rotatedSPS = sps
        rotatedSPS[rotatedSPS.count - 1] ^= 0xFF
        let events = try assembler.feed(stream([rotatedSPS, pps]))
        #expect(events.contains(.parameterSets(sps: rotatedSPS, pps: pps)))
    }

    @Test
    func trailingFrameFlushDeliversTheLastFrame() throws {
        var assembler = H264AnnexBAssembler()
        // No terminating start code after the slice: without the flush the
        // final frame of a burst would never display.
        let events = try assembler.feed(stream([sps, pps, idrSlice]))
        #expect(events.count == 1)  // just the parameter sets
        let flushed = try assembler.flushTrailing()
        #expect(flushed.count == 1)
        guard case .accessUnit(_, let isIDR) = flushed[0] else {
            Issue.record("expected access unit"); return
        }
        #expect(isIDR)
    }

    @Test
    func dropsNonVCLNALUs() throws {
        var assembler = H264AnnexBAssembler()
        let sei = Data([0x06, 0x05, 0x01, 0x00])
        let aud = Data([0x09, 0x10])
        var events = try assembler.feed(stream([sps, pps, sei, aud, idrSlice]))
        events += try assembler.flushTrailing()
        #expect(events.count == 2)  // parameter sets + IDR only
    }

    @Test
    func concatenatesMultiSliceAccessUnits() throws {
        var assembler = H264AnnexBAssembler()
        // Two slices of ONE frame — the second has first_mb_in_slice != 0
        // (first payload bit clear) — followed by the next frame's slice.
        let sliceA = Data([0x65, 0xB8, 0x00])
        let sliceB = Data([0x65, 0x24, 0x00])
        var events = try assembler.feed(stream([sps, pps, sliceA, sliceB, pSlice]))
        events += try assembler.flushTrailing()
        let accessUnits = events.compactMap { event -> Data? in
            if case .accessUnit(let data, _) = event { return data }
            return nil
        }
        #expect(accessUnits.count == 2)
        // Both slices of the first frame, each AVCC-framed, in one access unit.
        #expect(accessUnits[0].count == 4 + sliceA.count + 4 + sliceB.count)
    }

    // MARK: - Bounds

    @Test
    func rejectsOversizedLeadingGarbage() {
        var assembler = H264AnnexBAssembler()
        let garbage = Data(repeating: 0xAB, count: H264AnnexBAssembler.maxLeadingGarbage + 1)
        #expect(throws: H264AnnexBAssembler.ParseError.leadingGarbageExceeded) {
            _ = try assembler.feed(garbage)
        }
    }

    @Test
    func rejectsOversizedNALU() {
        var assembler = H264AnnexBAssembler()
        var data = Data([0, 0, 0, 1, 0x65])
        data.append(Data(repeating: 0x42, count: H264AnnexBAssembler.maxNALUSize + 8))
        #expect(throws: H264AnnexBAssembler.ParseError.naluTooLarge) {
            _ = try assembler.feed(data)
        }
    }

    @Test
    func rejectsOversizedParameterSet() {
        var assembler = H264AnnexBAssembler()
        var data = Data([0, 0, 0, 1, 0x67])
        data.append(Data(repeating: 0x11, count: H264AnnexBAssembler.maxParameterSetSize + 8))
        data.append(Data([0, 0, 0, 1, 0x68, 0xCE]))  // terminator so the SPS completes
        #expect(throws: H264AnnexBAssembler.ParseError.parameterSetTooLarge) {
            _ = try assembler.feed(data)
        }
    }

    @Test
    func rejectsUnboundedBuffering() {
        var assembler = H264AnnexBAssembler()
        let chunk = Data(repeating: 0x42, count: 1_024 * 1_024)
        #expect(throws: H264AnnexBAssembler.ParseError.self) {
            for _ in 0..<8 {
                _ = try assembler.feed(chunk)
            }
        }
    }

    @Test
    func preservesAPartialNALUAcrossALongChunkGap() async throws {
        var assembler = H264AnnexBAssembler()
        _ = try assembler.feed(stream([sps, pps]))
        // Only the first half of an IDR NALU arrives. The old stream timer
        // guessed that 15 ms of silence meant EOF, emitted this partial NALU,
        // and discarded its remainder. A USB scheduling gap is not a delimiter.
        var bigIDR = Data([0x65, 0xB8])
        bigIDR.append(Data(repeating: 0x42, count: 64))
        let firstEvents = try assembler.feed(startCode4 + bigIDR.prefix(30))
        // The new IDR start code completes the buffered PPS, so parameter-set
        // publication is allowed here; no access unit may be emitted yet.
        #expect(firstEvents.allSatisfy { event in
            if case .parameterSets = event { return true }
            return false
        })
        try await Task.sleep(for: .milliseconds(30))

        // The remainder completes the original NALU and must be preserved.
        var events = try assembler.feed(bigIDR.suffix(from: 30) + stream([pSlice]))
        events += try assembler.flushTrailing()
        let accessUnits = events.compactMap { event -> (Data, Bool)? in
            if case .accessUnit(let data, let isIDR) = event { return (data, isIDR) }
            return nil
        }
        #expect(accessUnits.count == 2)
        #expect(accessUnits[0].0.dropFirst(4) == bigIDR)
        #expect(accessUnits[0].1)
        #expect(accessUnits[1].0.dropFirst(4) == pSlice)
        #expect(!accessUnits[1].1)
    }

    @Test
    func continuationFragmentIsNeverASyncSample() throws {
        var assembler = H264AnnexBAssembler()
        _ = try assembler.feed(stream([sps, pps]))
        // A multi-slice IDR split across two pipe writes: the head slice in
        // one feed, the continuation slice (first_mb_in_slice != 0) in the
        // next. The fragment must not claim to be a sync sample — it could
        // otherwise seed a recording segment with half a frame.
        let headSlice = Data([0x65, 0xB8, 0x00])
        let continuationSlice = Data([0x65, 0x24, 0x00])
        var events = try assembler.feed(stream([headSlice]) + startCode4)
        events += try assembler.feed(continuationSlice + stream([pSlice]))
        events += try assembler.flushTrailing()
        let flags = events.compactMap { event -> Bool? in
            if case .accessUnit(_, let isIDR) = event { return isIDR }
            return nil
        }
        #expect(flags.count == 3)
        #expect(flags[0] == true)   // head slice: genuine IDR start
        #expect(flags[1] == false)  // continuation fragment: never sync
        #expect(flags[2] == false)  // following P-frame
    }

    @Test
    func zeroLengthNALUsAreDropped() throws {
        var assembler = H264AnnexBAssembler()
        // Two adjacent start codes produce a zero-length NALU between them.
        var data = Data()
        data.append(startCode4)
        data.append(startCode4)
        data.append(idrSlice)
        _ = try assembler.feed(stream([sps, pps]))
        var events = try assembler.feed(data)
        events += try assembler.flushTrailing()
        let accessUnits = events.filter { if case .accessUnit = $0 { true } else { false } }
        #expect(accessUnits.count == 1)
    }

    // MARK: - Incremental scan parity (#265)

    /// A stream that exercises every event path: leading garbage, 3- and
    /// 4-byte start codes, trailing zero bytes, dropped non-VCL units, a
    /// zero-length NALU, multi-slice IDR and P frames, an SPS change, and an
    /// unterminated final slice that only EOF completes.
    private var richStream: Data {
        var data = Data([0xAB, 0x00, 0x00, 0x02, 0x00])
        let units: [(code: Data, nalu: Data)] = [
            (startCode4, sps), (startCode3, pps), (startCode4, Data([0x09, 0x10])),
            (startCode3, Data([0x06, 0x05, 0x01, 0x00])),
            (startCode4, Data([0x65, 0xB8, 0x00, 0x00, 0x02])), (startCode3, Data([0x65, 0x24, 0x00])),
            (startCode4, Data()), (startCode4, pSlice), (startCode3, Data([0x41, 0x24, 0x00, 0x00])),
            (startCode4, Data([0x67, 0x42, 0xC0, 0x33, 0x8D])), (startCode4, pps), (startCode4, idrSlice),
            (startCode3, pSlice),
        ]
        for unit in units {
            data.append(unit.code)
            data.append(unit.nalu)
        }
        return data
    }

    @Test
    func matchesReferenceParserForEveryTwoChunkSplit() {
        let stream = richStream
        for split in 0...stream.count {
            let chunks = [stream.prefix(split), stream.suffix(from: split)].map { Data($0) }
            let actual = Self.run(H264AnnexBAssembler.self, chunks: chunks)
            let expected = Self.run(ReferenceH264AnnexBAssembler.self, chunks: chunks)
            #expect(actual == expected, "split at \(split)")
        }
    }

    @Test
    func matchesReferenceParserForOneByteFeeds() {
        let chunks = richStream.map { Data([$0]) }
        let actual = Self.run(H264AnnexBAssembler.self, chunks: chunks)
        #expect(actual == Self.run(ReferenceH264AnnexBAssembler.self, chunks: chunks))
        // Sanity: the stream really produces parameter-set changes and IDR flags.
        let events = actual.flatMap { step -> [H264AnnexBAssembler.Event] in
            if case .events(let events) = step { return events }
            return []
        }
        #expect(events.filter { if case .parameterSets = $0 { true } else { false } }.count == 2)
        #expect(events.contains { if case .accessUnit(_, true) = $0 { true } else { false } })
    }

    @Test
    func matchesReferenceParserForRandomStreamsAndChunkings() {
        var random = SplitMix64(seed: 0x265)
        for iteration in 0..<300 {
            let stream = Self.randomStream(using: &random)
            let chunks = Self.randomChunks(of: stream, using: &random)
            let actual = Self.run(H264AnnexBAssembler.self, chunks: chunks)
            let expected = Self.run(ReferenceH264AnnexBAssembler.self, chunks: chunks)
            #expect(actual == expected, "iteration \(iteration)")
        }
    }

    @Test
    func matchesReferenceParserOnBoundsViolations() {
        let maxNALU = H264AnnexBAssembler.maxNALUSize
        var oversizedNALU = Data([0, 0, 0, 1, 0x65])
        oversizedNALU.append(Data(repeating: 0x42, count: maxNALU + 8))
        var oversizedParameterSet = Data([0, 0, 0, 1, 0x67])
        oversizedParameterSet.append(Data(repeating: 0x11, count: H264AnnexBAssembler.maxParameterSetSize + 8))
        oversizedParameterSet.append(Data([0, 0, 0, 1, 0x68, 0xCE]))
        // Leading garbage whose start code arrives one byte past the limit.
        var lateStartCode = Data(repeating: 0xAB, count: H264AnnexBAssembler.maxLeadingGarbage + 1)
        lateStartCode.append(stream([sps, pps, idrSlice]))
        // A NALU exactly at the limit is accepted; one byte more is not.
        var limitNALU = Data([0, 0, 0, 1, 0x65, 0x80])
        limitNALU.append(Data(repeating: 0x42, count: maxNALU - 2))

        let cases: [(Data, Int)] = [
            (Data(repeating: 0xAB, count: H264AnnexBAssembler.maxLeadingGarbage + 1), 4_096),
            (lateStartCode, 1_000),
            (oversizedNALU, 256 * 1_024),
            (oversizedParameterSet, 7),
            (limitNALU, 512 * 1_024),
            (limitNALU + Data([0x42]), 512 * 1_024),
            (Data(repeating: 0x42, count: H264AnnexBAssembler.maxBufferSize + 1), H264AnnexBAssembler.maxBufferSize + 1),
        ]
        for (index, (input, chunkSize)) in cases.enumerated() {
            let chunks = stride(from: 0, to: input.count, by: chunkSize).map {
                input.subdata(in: $0..<min($0 + chunkSize, input.count))
            }
            let actual = Self.run(H264AnnexBAssembler.self, chunks: chunks)
            let expected = Self.run(ReferenceH264AnnexBAssembler.self, chunks: chunks)
            #expect(actual == expected, "case \(index)")
            let failed = actual.contains { step in
                if case .failed = step { return true }
                return false
            }
            #expect(failed == (index != 4), "case \(index)")
        }
    }

    #if DEBUG
    @Test
    func scansFragmentedInputApproximatelyOnce() throws {
        // One 256 KiB NALU delivered in 1 KiB reads, each read ending in the
        // first bytes of a would-be start code so the scanner must hold back
        // its overlap at every boundary.
        var assembler = H264AnnexBAssembler()
        // Payload byte i sits at stream offset i + 4, so each `00 00` lands on
        // the last two bytes of a 1 KiB read and its `03` opens the next.
        var payload = Data([0x65, 0x80])
        payload.append(Data(repeating: 0x55, count: 1_016))
        payload.append(contentsOf: [0x00, 0x00, 0x03])
        for _ in 0..<255 {
            payload.append(Data(repeating: 0x55, count: 1_021))
            payload.append(contentsOf: [0x00, 0x00, 0x03])
        }
        let stream = startCode4 + payload + startCode4 + pSlice
        var events: [H264AnnexBAssembler.Event] = []
        var feeds = 0
        for offset in stride(from: 0, to: stream.count, by: 1_024) {
            events += try assembler.feed(stream.subdata(in: offset..<min(offset + 1_024, stream.count)))
            feeds += 1
        }
        events += try assembler.flushTrailing()

        #expect(assembler.scannedPositionCount <= stream.count + 3 * feeds)
        let accessUnits = events.compactMap { event -> Data? in
            if case .accessUnit(let data, _) = event { return data }
            return nil
        }
        #expect(accessUnits.count == 2)
        #expect(accessUnits.first?.dropFirst(4) == payload)
    }
    #endif

    // MARK: - Parity helpers

    private enum Step: Equatable {
        case events([H264AnnexBAssembler.Event])
        case failed(H264AnnexBAssembler.ParseError?)
    }

    /// Feed every chunk, then flush at EOF, recording each call's outcome. A
    /// throw poisons the stream, so recording stops at the first failure.
    private static func run<Parser: AnnexBParsing>(_: Parser.Type, chunks: [Data]) -> [Step] {
        var parser = Parser()
        var steps: [Step] = []
        for chunk in chunks {
            do {
                steps.append(.events(try parser.feed(chunk)))
            } catch {
                steps.append(.failed(error as? H264AnnexBAssembler.ParseError))
                return steps
            }
        }
        do {
            steps.append(.events(try parser.flushTrailing()))
        } catch {
            steps.append(.failed(error as? H264AnnexBAssembler.ParseError))
        }
        return steps
    }

    /// Random NALU sequences biased toward 0x00/0x01 payload bytes so start
    /// codes, near-misses, and trailing zeros land everywhere.
    private static func randomStream(using random: inout SplitMix64) -> Data {
        let headers: [UInt8] = [0x67, 0x68, 0x65, 0x41, 0x01, 0x06, 0x09, 0x0C]
        var data = Data()
        if Bool.random(using: &random) {
            data.append(randomBytes(count: Int.random(in: 0...12, using: &random), using: &random))
        }
        for _ in 0..<Int.random(in: 1...24, using: &random) {
            data.append(Bool.random(using: &random) ? Data([0, 0, 0, 1]) : Data([0, 0, 1]))
            guard Int.random(in: 0..<12, using: &random) != 0 else { continue }  // zero-length NALU
            data.append(headers.randomElement(using: &random)!)
            data.append(randomBytes(count: Int.random(in: 0...40, using: &random), using: &random))
            if Int.random(in: 0..<4, using: &random) == 0 {
                data.append(Data(repeating: 0, count: Int.random(in: 1...3, using: &random)))
            }
        }
        return data
    }

    private static func randomBytes(count: Int, using random: inout SplitMix64) -> Data {
        Data((0..<count).map { _ -> UInt8 in
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<4: 0x00
            case 4: 0x01
            case 5: 0x80
            default: UInt8.random(in: 0...255, using: &random)
            }
        })
    }

    private static func randomChunks(of stream: Data, using random: inout SplitMix64) -> [Data] {
        let maxChunk = [1, 3, 8, 64, 4_096].randomElement(using: &random)!
        var chunks: [Data] = []
        var offset = 0
        while offset < stream.count {
            let size = Int.random(in: 1...maxChunk, using: &random)
            chunks.append(stream.subdata(in: offset..<min(offset + size, stream.count)))
            offset += size
        }
        return chunks
    }
}

private protocol AnnexBParsing {
    init()
    mutating func feed(_ chunk: Data) throws -> [H264AnnexBAssembler.Event]
    mutating func flushTrailing() throws -> [H264AnnexBAssembler.Event]
}

extension H264AnnexBAssembler: AnnexBParsing {}
extension ReferenceH264AnnexBAssembler: AnnexBParsing {}

/// Deterministic generator so parity failures reproduce from the seed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
