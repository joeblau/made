import Foundation

/// Incremental H.264 Annex-B → AVCC access-unit assembler for the raw
/// `screenrecord --output-format=h264` byte stream. Pure and allocation-bounded
/// — the unit-testable core of the untrusted-input story: the device (and
/// anything impersonating it through adb) controls every byte, so every bound
/// here is enforced BEFORE buffering. Any violation throws; the caller treats
/// that as a poisoned stream, kills the child, and restarts — bounded memory,
/// bounded blast radius.
struct H264AnnexBAssembler {
    enum Event: Equatable {
        /// A new SPS/PPS pair, byte-different from the pair previously in
        /// force. Byte-identical re-sends (every screenrecord respawn) are
        /// deliberately NOT re-emitted so the decoder never flush-flashes and
        /// an in-flight recording continues seamlessly across respawns.
        case parameterSets(sps: Data, pps: Data)
        /// One complete access unit, AVCC-framed (4-byte big-endian length
        /// prefix per NALU), ready for CMBlockBuffer wrapping.
        case accessUnit(data: Data, isIDR: Bool)
    }

    enum ParseError: Error, Equatable {
        case leadingGarbageExceeded
        case naluTooLarge
        case parameterSetTooLarge
        case bufferOverflow
    }

    /// Hard caps, enforced before allocation grows past them.
    static let maxLeadingGarbage = 64 * 1_024
    static let maxNALUSize = 2 * 1_024 * 1_024
    static let maxParameterSetSize = 1_024
    static let maxBufferSize = 4 * 1_024 * 1_024

    /// Raw stream bytes. `buffer[..<consumed]` is already emitted or
    /// discarded and is reclaimed lazily by `compact(beforeAppending:)`, so a
    /// completed NALU never costs a move of everything behind it.
    private var buffer: [UInt8] = []
    /// Bytes at the front of `buffer` that are no longer part of the stream.
    private var consumed = 0
    /// Absolute index where the next start-code scan resumes. Every position
    /// before it is proven not to begin a start code, so fragmented input is
    /// scanned once rather than from the NALU's start on every pipe read.
    private var scanCursor = 0
    #if DEBUG
    /// Test seam (Debug builds only): total candidate positions the
    /// start-code scan has covered, including the few re-examined when a
    /// start code may straddle a chunk boundary. Lets tests prove fragmented
    /// input is scanned approximately once; Release builds carry no counter.
    private(set) var scannedPositionCount = 0
    #endif
    private var sawFirstStartCode = false
    private var currentSPS: Data?
    private var currentPPS: Data?
    private var announcedSPS: Data?
    private var announcedPPS: Data?
    /// NALUs of the access unit currently being assembled (AVCC-framed).
    private var pendingAccessUnit = Data()
    private var pendingContainsIDR = false
    private var pendingContainsVCL = false
    /// Whether the pending AU's first slice had first_mb_in_slice == 0. A
    /// continuation fragment split across pipe writes must never be flagged
    /// as a sync sample (it could seed a recording segment or be enqueued as
    /// a decodable IDR when it is only the tail half of one).
    private var pendingStartsAccessUnit = true

    /// Bytes buffered but not yet emitted (leading garbage or the
    /// unterminated tail NALU).
    private var pendingByteCount: Int { buffer.count - consumed }

    /// Feed a chunk from the pipe; returns the events it completed.
    mutating func feed(_ chunk: Data) throws -> [Event] {
        guard pendingByteCount + chunk.count <= Self.maxBufferSize else {
            throw ParseError.bufferOverflow
        }
        compact(beforeAppending: chunk.count)
        buffer.append(contentsOf: chunk)

        var events: [Event] = []
        if !sawFirstStartCode {
            guard let first = nextStartCode() else {
                guard pendingByteCount <= Self.maxLeadingGarbage else {
                    throw ParseError.leadingGarbageExceeded
                }
                return events
            }
            guard first.index - consumed <= Self.maxLeadingGarbage else {
                throw ParseError.leadingGarbageExceeded
            }
            consume(through: first)
            sawFirstStartCode = true
        }

        // The pending bytes now begin with a NALU payload. Emit every NALU
        // that is terminated by a following start code; keep the
        // unterminated tail.
        while let next = nextStartCode() {
            let nalu = copyBytes(consumed..<next.index)
            consume(through: next)
            try handle(nalu: nalu, into: &events)
        }
        guard pendingByteCount <= Self.maxNALUSize else { throw ParseError.naluTooLarge }
        // Flush the batch's final access unit now rather than waiting for the
        // next chunk: encoders write whole frames per pipe write, so a
        // continuation slice split across writes is a tolerated rarity while
        // holding the AU would cost a frame of latency on every write.
        flushPendingAccessUnit(into: &events)
        return events
    }

    /// Emit the buffered trailing NALU only when the stream has reached EOF.
    /// Annex-B has no NAL length field, so byte silence can never prove that a
    /// tail is complete: USB scheduling may pause in the middle of one. The
    /// stream owner therefore calls this only after stdout closes.
    mutating func flushTrailing() throws -> [Event] {
        var events: [Event] = []
        if sawFirstStartCode, pendingByteCount > 0 {
            let nalu = copyBytes(consumed..<buffer.count)
            buffer = []
            consumed = 0
            scanCursor = 0
            try handle(nalu: nalu, into: &events)
        }
        flushPendingAccessUnit(into: &events)
        return events
    }

    // MARK: - Buffer management

    private mutating func consume(through startCode: (index: Int, length: Int)) {
        consumed = startCode.index + startCode.length
        scanCursor = consumed
    }

    private func copyBytes(_ range: Range<Int>) -> Data {
        guard !range.isEmpty else { return Data() }
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.count)
        return buffer.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress! + range.lowerBound, count: range.count)
        }
    }

    /// Reclaim the consumed prefix only once it is at least as large as the
    /// live tail (each byte is then moved O(1) times overall), or when
    /// appending would push the physical buffer past `maxBufferSize`.
    private mutating func compact(beforeAppending incoming: Int) {
        guard consumed > 0 else { return }
        guard consumed >= pendingByteCount || buffer.count + incoming > Self.maxBufferSize else { return }
        buffer.removeSubrange(0..<consumed)
        scanCursor -= consumed
        consumed = 0
    }

    // MARK: - NALU handling

    private mutating func handle(nalu: Data, into events: inout [Event]) throws {
        guard let header = nalu.first else { return }  // zero-length NALU: drop
        guard nalu.count <= Self.maxNALUSize else { throw ParseError.naluTooLarge }
        let type = header & 0x1F

        switch type {
        case 7:  // SPS
            guard nalu.count <= Self.maxParameterSetSize else { throw ParseError.parameterSetTooLarge }
            flushPendingAccessUnit(into: &events)
            currentSPS = nalu
            tryAnnounceParameterSets(into: &events)
        case 8:  // PPS
            guard nalu.count <= Self.maxParameterSetSize else { throw ParseError.parameterSetTooLarge }
            flushPendingAccessUnit(into: &events)
            currentPPS = nalu
            tryAnnounceParameterSets(into: &events)
        case 1, 5:  // VCL: non-IDR / IDR slice
            // A slice with first_mb_in_slice == 0 starts a new access unit;
            // continuation slices of a multi-slice frame merge into the
            // pending one. screenrecord emits single-slice frames in
            // practice; the multi-slice path is a correctness backstop.
            let startsAccessUnit = isFirstSliceOfAccessUnit(nalu)
            if pendingContainsVCL, startsAccessUnit {
                flushPendingAccessUnit(into: &events)
            }
            if !pendingContainsVCL {
                pendingStartsAccessUnit = startsAccessUnit
            }
            appendAVCC(nalu)
            pendingContainsVCL = true
            if type == 5 { pendingContainsIDR = true }
        default:  // AUD, SEI, filler, …: dropped
            break
        }
    }

    private mutating func tryAnnounceParameterSets(into events: inout [Event]) {
        guard let sps = currentSPS, let pps = currentPPS else { return }
        guard sps != announcedSPS || pps != announcedPPS else { return }
        announcedSPS = sps
        announcedPPS = pps
        events.append(.parameterSets(sps: sps, pps: pps))
    }

    private mutating func appendAVCC(_ nalu: Data) {
        var length = UInt32(nalu.count).bigEndian
        withUnsafeBytes(of: &length) { pendingAccessUnit.append(contentsOf: $0) }
        pendingAccessUnit.append(nalu)
    }

    private mutating func flushPendingAccessUnit(into events: inout [Event]) {
        guard pendingContainsVCL else {
            pendingAccessUnit = Data()
            pendingContainsIDR = false
            return
        }
        // A continuation fragment (an AU whose first slice isn't the frame's
        // first) is never a sync sample, whatever its slice types claim.
        events.append(.accessUnit(
            data: pendingAccessUnit,
            isIDR: pendingContainsIDR && pendingStartsAccessUnit
        ))
        pendingAccessUnit = Data()
        pendingContainsIDR = false
        pendingContainsVCL = false
        pendingStartsAccessUnit = true
    }

    /// first_mb_in_slice is the first exp-Golomb field after the 1-byte NAL
    /// header; a leading 1 bit encodes the value 0 = first slice of a frame.
    private func isFirstSliceOfAccessUnit(_ nalu: Data) -> Bool {
        guard nalu.count >= 2 else { return true }
        return (nalu[nalu.startIndex + 1] & 0x80) != 0
    }

    // MARK: - Start-code scan

    /// Find the first 00 00 01 / 00 00 00 01 start code at or after
    /// `scanCursor`, returning its absolute index. On a miss the cursor
    /// advances to the earliest position that later bytes could still turn
    /// into a start code (the final three bytes may be a split prefix).
    private mutating func nextStartCode() -> (index: Int, length: Int)? {
        let count = buffer.count
        let start = scanCursor
        let end = count - 2
        let found: (index: Int, length: Int)? = buffer.withUnsafeBufferPointer { bytes in
            var index = start
            while index < end {
                let third = bytes[index + 2]
                // No start code can begin at index, index + 1, or index + 2
                // unless bytes[index + 2] is 0 or 1.
                if third > 1 {
                    index += 3
                    continue
                }
                if bytes[index] == 0, bytes[index + 1] == 0 {
                    if third == 1 {
                        return (index, 3)
                    }
                    if index + 3 < count, bytes[index + 3] == 1 {
                        return (index, 4)
                    }
                }
                index += 1
            }
            return nil
        }
        #if DEBUG
        scannedPositionCount += found.map { $0.index + 1 - start } ?? max(0, end - start)
        #endif
        if found == nil {
            scanCursor = max(scanCursor, count - 3)
        }
        return found
    }
}
