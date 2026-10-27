import Foundation
import Security

enum BuildActivityRelay {
    static let endpoint = URL(string: "https://rendezvous.blau.app/live-activities/")!

    struct Registration: Encodable {
        let token: String
        let environment: String
        let runKey: String
    }
    struct Update: Encodable {
        let runKey: String
        let state: BuildActivityState
    }
    enum Failure: Error { case rejected(Int), invalidResponse }

    static func send<T: Encodable>(_ body: T, action: String, capability: String) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.rejected(response.statusCode) }
    }

    static func makeCapability() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func validCapability(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

/// One local monitor record. Capabilities never go into preferences or app-group files.
enum BuildMonitorStorage {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "app.blau").build-monitor",
         kSecAttrAccount as String: "active"]
    }

    static func load<T: Decodable>(_ type: T.Type) -> T? {
        var query = query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = query
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
