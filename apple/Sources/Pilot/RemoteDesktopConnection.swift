import Foundation
import Security
import SwiftData

/// A saved remote-desktop connection — one tab in the global Remote Desktop
/// section. Each connects to a machine's built-in VNC / Screen-Sharing server
/// (macOS advertises this as the Bonjour service `_rfb._tcp`).
///
/// Only non-secret connection metadata is persisted in SwiftData. When the user
/// opts into saving the password, it is stored separately in Keychain.
@Model
final class RemoteDesktopConnection {
    #Unique([\RemoteDesktopConnection.id])

    var id: UUID = UUID()
    /// Hostname or IP of the VNC server (e.g. "studio.local" or "192.168.1.20").
    var host: String = ""
    /// VNC port; macOS Screen Sharing listens on 5900 by default.
    var port: Int = 5900
    /// Optional friendly label; falls back to the host for the tab title.
    var nickname: String = ""
    /// Optional username for Apple Remote Desktop ("macOS") authentication.
    var username: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var lastConnectedAt: Date?

    init(host: String = "", port: Int = 5900, nickname: String = "", username: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.host = host
        self.port = port
        self.nickname = nickname
        self.username = username
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    /// Tab label: the nickname if set, else the host, else a placeholder.
    var displayTitle: String {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespaces)
        if !trimmedNickname.isEmpty { return trimmedNickname }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        return trimmedHost.isEmpty ? "New Connection" : trimmedHost
    }
}

/// Non-secret, per-connection VNC preferences. Clipboard sharing defaults to
/// off because a remote server can otherwise read or replace the local pasteboard.
enum VNCPreferences {
    private static let clipboardPrefix = "vnc.clipboard."
    private static let autoConnectPrefix = "vnc.autoConnect."

    static func isClipboardRedirectionEnabled(id: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: clipboardPrefix + id.uuidString)
    }

    static func setClipboardRedirectionEnabled(
        _ enabled: Bool,
        id: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: clipboardPrefix + id.uuidString)
    }

    /// Whether to connect on its own when the pane appears. It needs a saved
    /// password, so it is never on without one. Saving the password and
    /// auto-connecting used to be a single choice: a connection with a saved
    /// password and no stored preference is one that opted into both.
    static func isAutoConnectEnabled(
        id: UUID,
        hasSavedPassword: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard hasSavedPassword else { return false }
        return defaults.object(forKey: autoConnectPrefix + id.uuidString) as? Bool ?? true
    }

    static func setAutoConnectEnabled(
        _ enabled: Bool,
        id: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: autoConnectPrefix + id.uuidString)
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: clipboardPrefix + id.uuidString)
        defaults.removeObject(forKey: autoConnectPrefix + id.uuidString)
    }
}

/// Keychain store for VNC passwords, keyed by a connection's `id`. The password
/// stays out of the SwiftData model (and the synced store); whether one is saved
/// is inferred from Keychain presence, so no schema/migration is needed.
enum VNCKeychain {
    private static let service = "app.blau.pilot.vnc"

    static func save(_ password: String, id: UUID) {
        guard let data = password.data(using: .utf8) else { return }
        var query = baseQuery(id: id)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(id: UUID) -> String? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(id: UUID) {
        SecItemDelete(baseQuery(id: id) as CFDictionary)
    }

    private static func baseQuery(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}
