import CoreMedia
import Foundation

/// Builds a one-sample `CMSampleBuffer` around an already-encoded, length-
/// prefixed (AVCC/HVCC) video access unit. It owns only block allocation,
/// the payload copy, sample creation, and attachments; callers keep format
/// creation, clocks, queue ownership, backpressure, and decoder recovery.
///
/// The payload is copied into CoreMedia-owned memory, so the returned sample
/// stays valid after the source `Data` is released or mutated.
enum EncodedVideoSample {
    enum Failure: Error, Equatable {
        case emptyPayload
        case blockBuffer(OSStatus)
        case copy(OSStatus)
        case sampleBuffer(OSStatus)
    }

    /// Per-sample attachments, chosen explicitly by each caller.
    struct Attachments: Equatable, Sendable {
        /// Sets `kCMSampleAttachmentKey_DisplayImmediately`.
        var displayImmediately: Bool
        /// Sets `kCMSampleAttachmentKey_NotSync`. Leaving it false omits the
        /// key, which CoreMedia reads as a sync sample.
        var notSync: Bool

        /// Display on arrival, flagging non-keyframes as not sync.
        static func displayImmediately(isSync: Bool) -> Attachments {
            Attachments(displayImmediately: true, notSync: !isSync)
        }
    }

    static func make(
        payload: Data,
        format: CMFormatDescription,
        timing: CMSampleTimingInfo,
        attachments: Attachments
    ) throws(Failure) -> CMSampleBuffer {
        let count = payload.count
        guard count > 0 else { throw .emptyPayload }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw .blockBuffer(blockStatus)
        }

        let copyStatus = payload.withUnsafeBytes { rawBuffer in
            // Non-empty Data always has a base address.
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw .copy(copyStatus) }

        var timing = timing
        var sampleSize = count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { throw .sampleBuffer(sampleStatus) }

        apply(attachments, to: sampleBuffer)
        return sampleBuffer
    }

    private static func apply(_ attachments: Attachments, to sampleBuffer: CMSampleBuffer) {
        guard attachments.displayImmediately || attachments.notSync,
              let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        if attachments.displayImmediately {
            setTrue(kCMSampleAttachmentKey_DisplayImmediately, in: dictionary)
        }
        if attachments.notSync {
            setTrue(kCMSampleAttachmentKey_NotSync, in: dictionary)
        }
    }

    private static func setTrue(_ key: CFString, in dictionary: CFMutableDictionary) {
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
