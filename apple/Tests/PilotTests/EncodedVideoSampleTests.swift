import CoreMedia
import Foundation
import Testing
@testable import Pilot

/// The shared encoded-sample builder used by the Android mirror, the AirPlay
/// renderer, and Kneeboard's HEVC mirror. Callers own timing and attachment
/// policy, so these checks pin that both survive construction unchanged.
@Suite("Encoded video sample construction")
struct EncodedVideoSampleTests {
    private let payload = Data((0..<64).map { UInt8($0) })

    private func makeFormat(_ codec: CMVideoCodecType = kCMVideoCodecType_H264) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: 64,
            height: 48,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return try #require(status == noErr ? format : nil)
    }

    private func bytes(of sample: CMSampleBuffer) throws -> Data {
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        #expect(status == kCMBlockBufferNoErr)
        return data
    }

    private func attachment(_ key: CFString, of sample: CMSampleBuffer) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [NSDictionary], let first = attachments.first else { return nil }
        return first[key] as? Bool
    }

    @Test
    func copiesPayloadAndPreservesCallerTiming() throws {
        let format = try makeFormat(kCMVideoCodecType_HEVC)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 42, timescale: 60),
            decodeTimeStamp: .invalid
        )
        let sample = try EncodedVideoSample.make(
            payload: payload,
            format: format,
            timing: timing,
            attachments: .displayImmediately(isSync: true)
        )

        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(CMSampleBufferGetSampleSize(sample, at: 0) == payload.count)
        #expect(CMSampleBufferDataIsReady(sample))
        #expect(CMSampleBufferGetFormatDescription(sample) === format)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == timing.presentationTimeStamp)
        #expect(CMSampleBufferGetDuration(sample) == timing.duration)
        #expect(try bytes(of: sample) == payload)
    }

    @Test
    func sampleOutlivesItsReleasedSourceBuffer() throws {
        final class Released: @unchecked Sendable { var value = false }
        let released = Released()
        let count = payload.count
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        payload.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: count) }

        var sample: CMSampleBuffer?
        do {
            let source = Data(bytesNoCopy: pointer, count: count, deallocator: .custom { bytes, length in
                // Scribble before freeing so any aliasing would be visible.
                memset(bytes, 0xEE, length)
                bytes.deallocate()
                released.value = true
            })
            sample = try EncodedVideoSample.make(
                payload: source,
                format: try makeFormat(),
                timing: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid),
                attachments: .displayImmediately(isSync: true)
            )
        }

        #expect(released.value)
        #expect(try bytes(of: try #require(sample)) == payload)
    }

    @Test
    func callersSelectSyncAndDisplayAttachments() throws {
        let format = try makeFormat()
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        func make(_ attachments: EncodedVideoSample.Attachments) throws -> CMSampleBuffer {
            try EncodedVideoSample.make(payload: payload, format: format, timing: timing, attachments: attachments)
        }

        // Android / Kneeboard: display on arrival, non-keyframes marked.
        let keyframe = try make(.displayImmediately(isSync: true))
        #expect(attachment(kCMSampleAttachmentKey_DisplayImmediately, of: keyframe) == true)
        #expect(attachment(kCMSampleAttachmentKey_NotSync, of: keyframe) == nil)
        let interframe = try make(.displayImmediately(isSync: false))
        #expect(attachment(kCMSampleAttachmentKey_DisplayImmediately, of: interframe) == true)
        #expect(attachment(kCMSampleAttachmentKey_NotSync, of: interframe) == true)

        // AirPlay: display on arrival, sync flag deliberately left unset.
        let airPlay = try make(EncodedVideoSample.Attachments(displayImmediately: true, notSync: false))
        #expect(attachment(kCMSampleAttachmentKey_DisplayImmediately, of: airPlay) == true)
        #expect(attachment(kCMSampleAttachmentKey_NotSync, of: airPlay) == nil)

        let plain = try make(EncodedVideoSample.Attachments(displayImmediately: false, notSync: false))
        #expect(attachment(kCMSampleAttachmentKey_DisplayImmediately, of: plain) == nil)
        #expect(attachment(kCMSampleAttachmentKey_NotSync, of: plain) == nil)
    }

    @Test
    func emptyPayloadIsAControlledFailure() throws {
        let format = try makeFormat()
        #expect(throws: EncodedVideoSample.Failure.emptyPayload) {
            _ = try EncodedVideoSample.make(
                payload: Data(),
                format: format,
                timing: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid),
                attachments: .displayImmediately(isSync: true)
            )
        }
    }
}
