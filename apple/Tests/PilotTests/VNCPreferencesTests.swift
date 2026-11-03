import Foundation
import Testing
@testable import Pilot

@Suite("VNC privacy defaults")
struct VNCPreferencesTests {
    @Test("Clipboard redirection is disabled until explicitly enabled")
    func clipboardDefaultsOff() throws {
        let suiteName = "VNCPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()

        #expect(!VNCPreferences.isClipboardRedirectionEnabled(id: id, defaults: defaults))
        VNCPreferences.setClipboardRedirectionEnabled(true, id: id, defaults: defaults)
        #expect(VNCPreferences.isClipboardRedirectionEnabled(id: id, defaults: defaults))
        VNCPreferences.remove(id: id, defaults: defaults)
        #expect(!VNCPreferences.isClipboardRedirectionEnabled(id: id, defaults: defaults))
    }

    @Test("Auto-connect needs a saved password and is its own choice")
    func autoConnectIsSeparateFromSavingThePassword() throws {
        let suiteName = "VNCPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()

        // Never on without a saved password, even if previously enabled.
        #expect(!VNCPreferences.isAutoConnectEnabled(id: id, hasSavedPassword: false, defaults: defaults))
        // A password saved under the old combined checkbox kept auto-connect.
        #expect(VNCPreferences.isAutoConnectEnabled(id: id, hasSavedPassword: true, defaults: defaults))

        VNCPreferences.setAutoConnectEnabled(false, id: id, defaults: defaults)
        #expect(!VNCPreferences.isAutoConnectEnabled(id: id, hasSavedPassword: true, defaults: defaults))

        VNCPreferences.setAutoConnectEnabled(true, id: id, defaults: defaults)
        #expect(!VNCPreferences.isAutoConnectEnabled(id: id, hasSavedPassword: false, defaults: defaults))

        VNCPreferences.setAutoConnectEnabled(false, id: id, defaults: defaults)
        VNCPreferences.remove(id: id, defaults: defaults)
        #expect(VNCPreferences.isAutoConnectEnabled(id: id, hasSavedPassword: true, defaults: defaults))
    }
}
