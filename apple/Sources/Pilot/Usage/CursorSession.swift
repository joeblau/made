import CommonCrypto
import Foundation
import SQLite3

extension UsageSessions {
    // MARK: - Cursor (Anysphere)

    /// The editor's session, including Cursor's encrypted safeStorage format.
    /// Read-only: Cursor owns token refresh and the original credential store.
    struct CursorSession: Sendable {
        let accessToken: String
        /// JWT `sub`, e.g. `github|1218847`.
        let userId: String
        let expiresAt: Date?

        var isExpired: Bool { isExpired(at: Date()) }

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(date) <= 60
        }

        /// Load from the IDE's state database (read-only).
        static func load() -> CursorSession? {
            try? loadChecked()
        }

        enum LoadError: Error, Equatable {
            case missingDatabase, missingToken, keychainUnavailable, unreadableToken, expired

            var message: String {
                switch self {
                case .missingDatabase:
                    "Cursor: open the Cursor desktop app and sign in once, then check again. Signing in on the website or in the agent CLI does not create the desktop session Cockpit uses."
                case .missingToken:
                    "Cursor: no desktop session found. Open Cursor and sign in, then check again."
                case .keychainUnavailable:
                    "Cursor: Keychain access is needed to read its encrypted session. Unlock your login keychain, check again, and allow access to Cursor Safe Storage when macOS asks."
                case .unreadableToken:
                    "Cursor: the saved desktop session could not be read. Open Cursor and sign out and back in, then check again."
                case .expired:
                    "Cursor: the desktop session has expired. Open Cursor to renew it; if it stays expired, sign out and back in, then check again."
                }
            }
        }

        static func loadChecked(
            databaseURL: URL = stateDatabaseURL(),
            password: () -> String? = CursorSafeStorage.password
        ) throws -> CursorSession {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw LoadError.missingDatabase
            }
            guard let token = readStateItem(
                key: "cursorAuth/accessToken",
                databaseURL: databaseURL
            ) else { throw LoadError.missingToken }
            return try decodeStoredToken(token, password: password)
        }

        static func decodeStoredToken(_ stored: String, password: () -> String?) throws -> CursorSession {
            let token: String
            if stored.hasPrefix(CursorSafeStorage.prefix) {
                guard let password = password(), !password.isEmpty else { throw LoadError.keychainUnavailable }
                guard let plaintext = CursorSafeStorage.decrypt(stored, password: password) else {
                    throw LoadError.unreadableToken
                }
                token = plaintext
            } else {
                token = stored
            }
            guard let session = parse(token: token) else { throw LoadError.unreadableToken }
            return session
        }

        /// Decode the JWT's `sub` and `exp` claims. Internal so tests can
        /// cover it with fabricated tokens.
        static func parse(token: String) -> CursorSession? {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = trimmed.split(separator: ".")
            guard segments.count == 3,
                  let payload = base64URLDecode(String(segments[1])),
                  let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let subject = claims["sub"] as? String,
                  !subject.isEmpty else { return nil }
            let expiresAt = (claims["exp"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            return CursorSession(accessToken: trimmed, userId: subject, expiresAt: expiresAt)
        }

        static func stateDatabaseURL() -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }

        /// Read one `ItemTable` value. Internal so tests can point at a
        /// fixture database instead of a developer's real IDE state.
        static func readStateItem(key: String, databaseURL: URL) -> String? {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databaseURL.path, &database, SQLITE_OPEN_READONLY, nil
            ) == SQLITE_OK, let database else {
                sqlite3_close(database)
                return nil
            }
            defer { sqlite3_close(database) }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil
            ) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else { return nil }
            let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        private static func base64URLDecode(_ segment: String) -> Data? {
            var base64 = segment
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64.append("=") }
            return Data(base64Encoded: base64)
        }
    }

}

/// Interoperates with Electron's macOS safeStorage v10 encoding. The format is
/// defined by Chromium's os_crypt_mac.mm: PBKDF2-HMAC-SHA1 and AES-128-CBC.
/// The password is read only after provider opt-in, never logged or persisted.
enum CursorSafeStorage {
    static let prefix = "cursor-safe-storage:v1:"

    static func password() -> String? {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "Cursor Safe Storage", "-w"],
            timeout: .seconds(30), standardOutputLimit: 4_096, standardErrorLimit: 4_096
        )
        guard let result = try? ProcessRunner.runBlocking(invocation),
              result.termination == .exit(0),
              let value = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .newlines), !value.isEmpty else { return nil }
        return value
    }

    static func decrypt(_ stored: String, password: String) -> String? {
        guard stored.hasPrefix(prefix), stored.utf8.count <= 65_536,
              let data = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              data.starts(with: Data("v10".utf8)), data.count > 3,
              (data.count - 3).isMultiple(of: kCCBlockSizeAES128) else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = password.withCString { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes, password.utf8.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1_003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let ciphertext = Array(data.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var count = 0
        let result = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, ciphertext, ciphertext.count, &plaintext, plaintext.count, &count)
        defer { _ = plaintext.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard result == kCCSuccess else { return nil }
        return String(bytes: plaintext.prefix(count), encoding: .utf8)
    }
}
