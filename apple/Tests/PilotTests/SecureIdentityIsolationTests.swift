import Foundation
import Testing
@testable import Pilot

@MainActor
struct SecureIdentityIsolationTests {
    @Test("Isolated identities stay disconnected through settings actions and incoming peer keys")
    func isolationSurvivesLifecycleActions() {
        let identity = SecureIdentity(role: .pilot, isolated: true)
        let validPublicKey = Data((0..<32).map(UInt8.init)).base64EncodedString()
        var announcements = 0
        identity.send = { _ in announcements += 1 }

        for _ in 0..<2 {
            identity.regenerate()
            identity.refreshPeer()
            identity.receive(DeviceKeyAnnounce(role: .copilot, publicKey: validPublicKey))
            identity.announce()
        }

        #expect(identity.isIsolated)
        #expect(identity.localPublicKey == nil)
        #expect(identity.peerPublicKey == nil)
        #expect(!identity.isSynced)
        #expect(announcements == 0)
    }
}
