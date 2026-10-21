import AVFoundation
import AppKit

/// The layer is mounted by AppKit; its sampleBufferRenderer and all decoder
/// state are used only on the receiver's dedicated queue, never the main actor.
final class AirPlayVideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private var sps = Data()
    private var pps = Data()
    private var format: CMVideoFormatDescription?
    private var needsKeyframe = true

    @MainActor init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    func consume(_ payload: Data) throws -> Bool {
        let packet = try AirPlayH264AccessUnit(payload)
        var changed = false
        for parameter in packet.parameterSets {
            if parameter.first.map({ $0 & 0x1F }) == 7, parameter != sps {
                sps = parameter
                changed = true
            } else if parameter.first.map({ $0 & 0x1F }) == 8, parameter != pps {
                pps = parameter
                changed = true
            }
        }
        if changed {
            format = makeFormat()
            needsKeyframe = true
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        }
        guard let format, !packet.sample.isEmpty else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= 8192, dimensions.height <= 8192 else {
            throw AirPlayPacketDecoder.Failure.invalidPacket
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: true)
            needsKeyframe = true
        }
        guard renderer.isReadyForMoreMediaData else {
            // A dropped reference frame invalidates the rest of its GOP.
            needsKeyframe = true
            return false
        }
        guard !needsKeyframe || packet.isKeyframe else { return false }
        // AirPlay samples carry no PTS and display on arrival; the sync flag
        // is deliberately left unset (keyframe gating happens above).
        guard let sample = try? EncodedVideoSample.make(
            payload: packet.sample,
            format: format,
            timing: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid),
            attachments: EncodedVideoSample.Attachments(displayImmediately: true, notSync: false)
        ) else { return false }
        needsKeyframe = false
        renderer.enqueue(sample)
        return true
    }

    func reset() {
        sps.removeAll()
        pps.removeAll()
        format = nil
        needsKeyframe = true
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        return sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                var result: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &result
                ) == noErr else { return nil }
                return result
            }
        }
    }
}
