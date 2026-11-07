import Foundation

/// Redacted text plus what the policy did to it.
struct AgentRedaction: Equatable, Sendable {
    var text: String
    /// True when any secret span was masked; drives the `redacted` chip.
    var redacted: Bool
    /// Lines dropped past `maximumLines`; drives `truncated · show all`.
    var truncatedLines: Int
}

/// Masks secrets, then truncates to `maximumLines` (nil: no limit).
/// Replacement is `••••`; keyed values keep their key.
func redactOutput(_ text: String, maximumLines: Int? = 200) -> AgentRedaction {
    // WP3: implement
    AgentRedaction(text: text, redacted: false, truncatedLines: 0)
}

/// Redacts secret-named keys' values and every string value, recursively.
func redactJSON(_ value: JSONValue) -> (value: JSONValue, redacted: Bool) {
    // WP3: implement
    (value, false)
}

/// Single-line redaction for labels, tooltips, and accessibility text.
func redactInline(_ text: String) -> String {
    // WP3: implement
    text
}
