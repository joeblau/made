import Foundation
import Testing
@testable import Pilot

@Suite("Built privacy manifest")
struct PrivacyManifestTests {
    @Test("Pilot declares camera access before opening a device pane")
    func cameraUsageDescriptionIsPresent() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        #expect(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    @Test("made embeds the reviewed Sparkle update policy")
    func sparkleUpdatePolicyIsPresent() {
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
                == "https://github.com/joeblau/made/releases/latest/download/appcast.xml"
        )
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
                == "BIQoEzT2ALEKrU/qHI6ZCBZXrHMmq+GQxRgy9dCpEBg="
        )
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
    }
}
