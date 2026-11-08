import Foundation

struct IOSCaptureDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let modelID: String

    var detail: String? {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              trimmedModel.localizedCaseInsensitiveCompare(name) != .orderedSame else { return nil }
        return trimmedModel
    }
}

/// Conservative admission policy for the CMIO sources shown in the iOS
/// picker. AVFoundation does not expose a public "this is an iOS screen"
/// flag, so explicit iPhone/iPad identity metadata is the strongest signal.
/// A generic muxed source is admitted only when AVFoundation identifies its
/// manufacturer as Apple and its transport as USB; this keeps ordinary capture
/// cards and webcams out without dropping a renamed tethered iPhone whose
/// display/model name is generic.
enum IOSCaptureDiscoveryPolicy {
    /// `kIOAudioDeviceTransportTypeUSB` (`'usb '`). `AVCaptureDevice` exposes
    /// the value but AVFoundation does not provide a Swift-native enum for it.
    private static let usbTransportType = Int32(bitPattern: 0x7573_6220)

    static func includes(
        name: String,
        modelID: String,
        manufacturer: String,
        isMuxed: Bool,
        transportType: Int32
    ) -> Bool {
        let identity = "\(name) \(modelID)"
        let identityWords = identity.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let hasIOSIdentity = identity.localizedCaseInsensitiveContains("iphone")
            || identity.localizedCaseInsensitiveContains("ipad")
            || identityWords.contains {
                $0.localizedCaseInsensitiveCompare("ios") == .orderedSame
            }
        if hasIOSIdentity { return true }

        let normalizedManufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        return isMuxed
            && normalizedManufacturer.localizedCaseInsensitiveCompare("Apple Inc.") == .orderedSame
            && transportType == usbTransportType
    }
}

enum IOSCaptureAudioPairingPolicy {
    /// AVFoundation exposes no public relationship between separate video and
    /// audio capture devices. Only identical unique IDs are authoritative;
    /// names and model IDs are not unique when two phones are connected.
    static func matches(videoUniqueID: String, audioUniqueID: String) -> Bool {
        videoUniqueID == audioUniqueID
    }
}
