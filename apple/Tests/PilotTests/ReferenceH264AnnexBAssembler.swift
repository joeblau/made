import Foundation
@testable import Pilot

/// Test oracle: the pre-#265 assembler, which rescanned each unterminated
/// NALU from its first byte on every feed and compacted after every NALU.
/// Its events are the behavioral contract the incremental parser must match
/// byte for byte under any chunking. Kept verbatim apart from the type name
/// and shared Event/ParseError/limit declarations; do not "fix" it.
struct ReferenceH264AnnexBAssembler {
    typealias Event = H264AnnexBAssembler.Event
    typealias ParseError = H264AnnexBAssembler.ParseError

    /// Hard caps, enforced before allocation grows past them.
    static let maxLeadingGarbage = H264AnnexBAssembler.maxLeadingGarbage
    static let maxNALUSize = H264AnnexBAssembler.maxNALUSize
    static let maxParameterSetSize = H264AnnexBAssembler.maxParameterSetSize
    static let maxBufferSize = H264AnnexBAssembler.maxBufferSize

    private var buffer = Data()
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

    /// Feed a chunk from the pipe; returns the events it completed.
    mutating func feed(_ chunk: Data) throws -> [Event] {
        guard buffer.count + chunk.count <= Self.maxBufferSize else {
            throw ParseError.bufferOverflow
        }
        buffer.append(chunk)

        var events: [Event] = []
        if !sawFirstStartCode {
            guard let first = findStartCode(in: buffer, from: 0) else {
                guard buffer.count <= Self.maxLeadingGarbage else {
                    throw ParseError.leadingGarbageExceeded
                }
                return events
            }
            guard first.index <= Self.maxLeadingGarbage else {
                throw ParseError.leadingGarbageExceeded
            }
            buffer.removeSubrange(0..<(first.index + first.length))
            sawFirstStartCode = true
        }

        // The buffer now begins with a NALU payload. Emit every NALU that is
        // terminated by a following start code; keep the unterminated tail.
        while let next = findStartCode(in: buffer, from: 0) {
            let nalu = buffer.prefix(next.index)
            buffer.removeSubrange(0..<(next.index + next.length))
            try handle(nalu: Data(nalu), into: &events)
        }
        guard buffer.count <= Self.maxNALUSize else { throw ParseError.naluTooLarge }
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
        if sawFirstStartCode, !buffer.isEmpty {
            let nalu = buffer
            buffer = Data()
            try handle(nalu: nalu, into: &events)
        }
        flushPendingAccessUnit(into: &events)
        return events
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

    /// Find the next 00 00 01 / 00 00 00 01 start code at or after `from`.
    private func findStartCode(in data: Data, from: Int) -> (index: Int, length: Int)? {
        guard data.count >= 3 else { return nil }
        var index = from
        let end = data.count - 2
        while index < end {
            if data[data.startIndex + index] == 0, data[data.startIndex + index + 1] == 0 {
                if data[data.startIndex + index + 2] == 1 {
                    return (index, 3)
                }
                if index + 3 < data.count, data[data.startIndex + index + 2] == 0,
                   data[data.startIndex + index + 3] == 1 {
                    return (index, 4)
                }
                // 00 00 followed by neither 00/01: skip past the second zero.
                index += 1
            } else {
                index += 1
            }
        }
        return nil
    }
}
