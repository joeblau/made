import Foundation

/// Shared "8 minutes ago" formatting for the inspector's metadata lines, so
/// pull requests, workflow runs, and issues phrase and parse time identically
/// instead of each tab drifting into its own wording.
enum RelativeTime {

    /// Formats an ISO-8601 timestamp, returning the input unchanged when it
    /// cannot be parsed — a raw timestamp beats an empty cell.
    static func string(fromISO iso: String) -> String {
        guard let date = parseISODate(iso) else { return iso }
        return string(from: date)
    }

    static func string(from date: Date) -> String {
        relativeFormatterLock.lock()
        defer { relativeFormatterLock.unlock() }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatterLock = NSLock()
    private nonisolated(unsafe) static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static func parseISODate(_ value: String) -> Date? {
        isoFractionalFormatter.date(from: value) ?? isoFormatter.date(from: value)
    }

    // ISO8601DateFormatter is documented thread-safe, and these are never
    // mutated after init — hence nonisolated(unsafe) is sound. Building one
    // per parsed row (30 rows per 30s refresh) was measurable churn.
    private nonisolated(unsafe) static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
