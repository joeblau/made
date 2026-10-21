import Foundation
import Testing
import XCTest
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
    func chunkedFeedsMatchOneShotFeed() throws {
        // Large single-slice NALUs whose payloads embed zero runs (00 00 02 /
        // 00 00 00 02 — never a start code) so every chunk boundary lands in
        // the scanner's trickiest state, including NAL bytes and start codes
        // split across feed boundaries.
        var bigIDR = Data([0x65, 0xB8])
        var bigP = Data([0x41, 0x9A])
        for i in 0..<4_096 {
            bigIDR.append(contentsOf: [0, 0, 2, UInt8(truncatingIfNeeded: i) | 1])
            bigP.append(contentsOf: [0, 0, 0, 2, UInt8(truncatingIfNeeded: i) | 1])
        }
        let full = stream([sps, pps, bigIDR, bigP, pSlice])

        var oneShot = H264AnnexBAssembler()
        var expected = try oneShot.feed(full)
        expected += try oneShot.flushTrailing()
        #expect(expected.count == 4)  // parameter sets + three access units
        #expect(expected[0] == .parameterSets(sps: sps, pps: pps))
        guard case .accessUnit(let idrData, true) = expected[1] else {
            Issue.record("expected IDR access unit"); return
        }
        #expect(idrData.dropFirst(4) == bigIDR)

        for chunkSize in [1, 2, 3, 4, 5, 7, 64, 1_024] {
            var assembler = H264AnnexBAssembler()
            var events: [H264AnnexBAssembler.Event] = []
            var offset = 0
            while offset < full.count {
                let next = min(offset + chunkSize, full.count)
                events += try assembler.feed(full.subdata(in: offset..<next))
                offset = next
            }
            events += try assembler.flushTrailing()
            #expect(events == expected, "chunk size \(chunkSize)")
        }
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
}

/// Throughput benchmark for the start-code scanner: a few MB of synthetic
/// annex-B fed in 64 KB chunks, the shape of a keyframe arriving across many
/// pipe reads — the case the assembler's scan watermark exists for. XCTest
/// because Swift Testing has no `measure` equivalent.
final class H264AnnexBAssemblerPerformanceTests: XCTestCase {
    func testChunkedFeedThroughput() {
        var full = Data()
        full.append(contentsOf: [0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x32, 0x8D, 0x68])
        full.append(contentsOf: [0, 0, 0, 1, 0x68, 0xCE, 0x01, 0xA8])
        // Payload bytes are never zero, so the only start codes are the real
        // ones; each ~512 KB NALU stays buffered across several feeds.
        var payload = Data(capacity: 512 * 1_024)
        for i in 0..<(512 * 1_024) {
            payload.append(UInt8(truncatingIfNeeded: i) | 1)
        }
        for i in 0..<8 {
            full.append(contentsOf: [0, 0, 0, 1, i == 0 ? 0x65 : 0x41, 0xB8])
            full.append(payload)
        }
        let chunkSize = 64 * 1_024
        var chunks: [Data] = []
        var offset = 0
        while offset < full.count {
            let next = min(offset + chunkSize, full.count)
            chunks.append(full.subdata(in: offset..<next))
            offset = next
        }

        measure {
            var assembler = H264AnnexBAssembler()
            var accessUnits = 0
            do {
                for chunk in chunks {
                    for event in try assembler.feed(chunk) {
                        if case .accessUnit = event { accessUnits += 1 }
                    }
                }
                for event in try assembler.flushTrailing() {
                    if case .accessUnit = event { accessUnits += 1 }
                }
            } catch {
                XCTFail("feed threw: \(error)")
            }
            XCTAssertEqual(accessUnits, 8)
        }
    }
}
