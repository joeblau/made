import Foundation

/// Outcome of one provider fetch.
enum ProviderFetch: Sendable {
    case success(ProviderUsage)
    case notSignedIn
    /// The endpoint returned 429; `retryAfter` is the server's hint, if any.
    case rateLimited(retryAfter: TimeInterval?)
    /// Not attempted this tick (min-spacing / backoff).
    case skipped
    case failure(String)
}

enum UsageFetchError: Error, Equatable {
    case http(status: Int, retryAfter: TimeInterval?)
    case malformed
}

/// The single network boundary shared by every provider adapter.
enum UsageHTTP {
    /// Performs one request. Injected so adapters can be exercised without the
    /// network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let live: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    /// GET a JSON object, tolerating any field shape — these are undocumented
    /// endpoints whose schemas vary, so we parse defensively rather than with a
    /// strict `Decodable` that would throw on the first type mismatch.
    static func getJSONObject(
        url: URL,
        headers: [String: String],
        transport: Transport
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Double($0) }
            throw UsageFetchError.http(status: http.statusCode, retryAfter: retryAfter)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.malformed
        }
        return object
    }

    /// Turn a thrown fetch error into a `ProviderFetch`, routing 429s to the
    /// backoff path and everything else to a displayable failure.
    static func classify(_ error: Error, provider: String, cli: String) -> ProviderFetch {
        if case let UsageFetchError.http(status, retryAfter) = error, status == 429 {
            return .rateLimited(retryAfter: retryAfter)
        }
        return .failure(describe(error, provider: provider, reauth: cli))
    }

    private static func describe(_ error: Error, provider: String, reauth cli: String) -> String {
        switch error {
        case UsageFetchError.http(let status, _) where status == 401 || status == 403:
            return "\(provider): session expired — re-run `\(cli)` to sign in."
        case UsageFetchError.http(let status, _):
            return "\(provider): request failed (HTTP \(status))."
        default:
            return "\(provider): couldn’t read the usage response."
        }
    }
}

/// Tolerant coercions for loosely typed provider JSON.
enum UsageJSON {
    /// Coerce a JSON value to a Double whether it arrived as a number or a string.
    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func number(_ dict: [String: Any], keys: [String]) -> Double? {
        number(value(dict, keys: keys))
    }

    static func bool(_ dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = dict[key] as? NSNumber { return value.boolValue }
            if let value = dict[key] as? String {
                if value.caseInsensitiveCompare("true") == .orderedSame || value == "1" { return true }
                if value.caseInsensitiveCompare("false") == .orderedSame || value == "0" { return false }
            }
        }
        return nil
    }

    static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func dictionary(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    static func value(_ dict: [String: Any], keys: [String]) -> Any? {
        for key in keys where dict[key] != nil { return dict[key] }
        return nil
    }

    /// Parse a reset timestamp from either unix seconds (Codex) or a string in a
    /// range of ISO-8601 / RFC formats (Claude).
    static func date(_ any: Any?) -> Date? {
        if let numeric = number(any) { return unixDate(numeric) }
        guard let string = any as? String, !string.isEmpty else { return nil }

        for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
                        ISO8601DateFormatter.Options([.withInternetDateTime])] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let parsed = iso.date(from: string) { return parsed }
        }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                        "yyyy-MM-dd HH:mm:ssZZZZZ",
                        "EEE',' dd MMM yyyy HH':'mm':'ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let parsed = formatter.date(from: string) { return parsed }
        }
        return nil
    }

    private static func unixDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    /// Human name for a rolling window given its length in seconds.
    static func windowName(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        let hours = seconds / 3600
        if hours <= 1.5 { return "Hourly" }
        if hours < 24 { return "\(Int(hours.rounded()))-hour" }
        let days = seconds / 86400
        if days <= 1.5 { return "Daily" }
        if days <= 7.5 { return "Weekly" }
        if days <= 31 { return "Monthly" }
        return "\(Int(days.rounded()))-day"
    }
}
