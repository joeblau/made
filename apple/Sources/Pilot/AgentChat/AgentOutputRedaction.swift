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
/// Replacement is `••••`; keyed values keep their key. Redacting before
/// truncating means a secret straddling the cut can't leak its head.
func redactOutput(_ text: String, maximumLines: Int? = 200) -> AgentRedaction {
    let masked = AgentRedactionPolicy.mask(text, rules: AgentRedactionPolicy.allRules)
    guard let maximumLines, maximumLines >= 0 else {
        return AgentRedaction(text: masked.text, redacted: masked.redacted, truncatedLines: 0)
    }
    let (kept, dropped) = AgentRedactionPolicy.truncateLines(masked.text, maximumLines: maximumLines)
    return AgentRedaction(text: kept, redacted: masked.redacted, truncatedLines: dropped)
}

/// Redacts secret-named keys' values and every string value, recursively.
/// In string arrays (argv), the element after a secret flag (`--token`) is
/// masked too.
func redactJSON(_ value: JSONValue) -> (value: JSONValue, redacted: Bool) {
    var redacted = false
    let result = AgentRedactionPolicy.redactJSON(value, redacted: &redacted)
    return (result, redacted)
}

/// Single-line redaction for labels, tooltips, and accessibility text:
/// masks secrets, then folds line breaks and control characters into single
/// spaces and escapes bidi overrides so a label can't reorder itself.
func redactInline(_ text: String) -> String {
    let masked = AgentRedactionPolicy.mask(text, rules: AgentRedactionPolicy.allRules).text
    return AgentRedactionPolicy.singleLine(masked)
}

/// Prose and notices keep their layout and are masked only for known-secret
/// shapes (prefixed tokens, bearer tokens, Authorization headers, PEM keys),
/// so ordinary sentences like "the token is invalid" stay untouched.
func redactProse(_ text: String) -> String {
    AgentRedactionPolicy.mask(text, rules: AgentRedactionPolicy.proseRules).text
}

/// Whole-content mask for files whose name marks them as secrets (`.env*`,
/// `*.pem`, `id_rsa*`, `id_ed25519*`, `.netrc`, `.npmrc`, `credentials*`);
/// everything else goes through `redactOutput`.
func redactFileContent(path: String, text: String, maximumLines: Int? = 200) -> AgentRedaction {
    guard isSecretLikePath(path) else { return redactOutput(text, maximumLines: maximumLines) }
    return AgentRedaction(text: text.isEmpty ? "" : AgentRedactionPolicy.maskText, redacted: !text.isEmpty, truncatedLines: 0)
}

/// True for file names whose whole content is treated as secret.
func isSecretLikePath(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    guard !name.isEmpty else { return false }
    if name.hasPrefix(".env") || name.hasSuffix(".pem") || [".netrc", ".npmrc", ".pgpass", ".git-credentials"].contains(name) {
        return true
    }
    if name == "config.json", (path as NSString).deletingLastPathComponent.lowercased().hasSuffix(".docker") { return true }
    return name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("credentials")
}

/// True when a step reads or writes a file whose whole content is masked:
/// any location, edit, subject, diff, or `*path*` input field names one.
func agentStepTouchesSecretFile(_ tool: AgentChatItem.ToolCall, input: JSONValue?, blocks: [ACPToolContent] = [],
                                secretPath: (String) -> Bool = isSecretLikePath) -> Bool {
    var paths = tool.locations.prefix(64).map(\.path) + tool.edits.prefix(64).map(\.path) + [tool.subject].compactMap { $0 }
    for case .diff(let path, _, _) in blocks.prefix(64) { paths.append(path) }
    if case .object(let object)? = input {
        paths += object.compactMap { key, value in key.lowercased().contains("path") ? value.stringValue : nil }
    }
    return paths.contains(where: secretPath)
}

/// Masks every string in a secret file's payload except path fields and what
/// the step runs or looks for (`command`, `cmd`, `pattern`, `query`, `url`),
/// so the file content never reaches a sink while a shell request still shows
/// exactly what will run (with the ordinary key-pattern redaction).
func maskSecretFileContent(_ value: JSONValue, key: String = "") -> JSONValue {
    switch value {
    case .string(let text):
        key.lowercased().contains("path") || secretFileVisibleFields.contains(key.lowercased()) || text.isEmpty
            ? value : .string(AgentRedactionPolicy.maskText)
    case .array(let list): .array(list.map { maskSecretFileContent($0, key: key) })
    case .object(let object): .object(Dictionary(uniqueKeysWithValues: object.map { ($0, maskSecretFileContent($1, key: $0)) }))
    case .null, .bool, .number: value
    }
}

private let secretFileVisibleFields: Set<String> = ["command", "cmd", "pattern", "query", "url"]

/// Redacts off the main actor when `text` exceeds
/// `AgentRedactionPolicy.offMainThresholdBytes`; smaller text runs inline.
func redactOutputInBackground(_ text: String, maximumLines: Int? = 200) async -> AgentRedaction {
    guard text.utf8.count > AgentRedactionPolicy.offMainThresholdBytes else {
        return redactOutput(text, maximumLines: maximumLines)
    }
    return await Task.detached(priority: .userInitiated) {
        redactOutput(text, maximumLines: maximumLines)
    }.value
}

/// A small bounded cache of redactions keyed by (item key, revision,
/// variant). A new revision of a key replaces its older entries; past
/// `capacity`, the oldest insertions go first.
@MainActor
final class AgentRedactionCache {
    struct Key: Hashable, Sendable {
        var key: String
        var revision: Int
        /// Distinguishes several texts of one item, e.g. "input" / "output:200".
        var variant: String
    }

    let capacity: Int
    private var entries: [Key: AgentRedaction] = [:]
    private var order: [Key] = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func redaction(
        key: String,
        revision: Int,
        variant: String = "",
        compute: () -> AgentRedaction
    ) -> AgentRedaction {
        let cacheKey = Key(key: key, revision: revision, variant: variant)
        if let hit = entries[cacheKey] { return hit }
        let value = compute()
        insert(value, for: cacheKey)
        return value
    }

    func cached(key: String, revision: Int, variant: String = "") -> AgentRedaction? {
        entries[Key(key: key, revision: revision, variant: variant)]
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private func insert(_ value: AgentRedaction, for cacheKey: Key) {
        let stale = order.filter { $0.key == cacheKey.key && $0.variant == cacheKey.variant && $0.revision != cacheKey.revision }
        if !stale.isEmpty {
            for old in stale { entries[old] = nil }
            order.removeAll { stale.contains($0) }
        }
        entries[cacheKey] = value
        order.append(cacheKey)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }
}

// MARK: - Policy

/// The pattern table. Every quantifier is bounded so hostile input can't make
/// a match run away; prefixed tokens carry minimum lengths so words like
/// `sk-learn` and git SHAs never match.
enum AgentRedactionPolicy {
    static let maskText = "••••"
    static let offMainThresholdBytes = 64 * 1_024

    struct Rule: Sendable {
        enum Replacement: Sendable {
            /// Mask the whole match.
            case whole
            /// Keep the match's first capture group, mask the rest.
            case keepFirstGroup
            /// Keep the token's known prefix (≤ 4 characters) when the token is
            /// ≥ 16 characters; shorter tokens are fully masked.
            case prefixHint
            /// Keyed value: keep key and separator (group 1), mask the value
            /// (group 2, 3, or 4); unquoted literals (numbers, booleans, null,
            /// `$VAR` references) are left alone. Group 1 opens with the
            /// whole key token, kept only when a secret key name ends it.
            case keyedValue
            /// `keyedValue` for a CLI flag token (`--api-key value`).
            case flagValue
        }

        var name: String
        var regex: NSRegularExpression
        var replacement: Replacement
        /// Cheap lowercase substrings, one of which must occur before the
        /// regex runs. Empty: always run.
        var hints: [String]
    }

    private static func rule(_ name: String, _ pattern: String, _ replacement: Rule.Replacement, caseInsensitive: Bool = false, hints: [String]) -> Rule {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // The patterns are compile-time literals covered by tests.
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return Rule(name: name, regex: regex, replacement: replacement, hints: hints)
    }

    /// Key names whose values are secret: any name ending in a secret word,
    /// joined by `_`, `-`, `.` or nothing (`accessToken`, `PGPASSWORD`); a
    /// `secret` segment anywhere (`SECRET_KEY_BASE`); `*_KEY`, `*_PASS`,
    /// `*_PWD` behind a separator; qualified keys (`privateKey`); and `auth`.
    static let secretKeyPattern =
        #"(?:[A-Za-z0-9]{1,64}[_.-]){0,8}[A-Za-z0-9]{0,64}(?:password|passwd|secret|token|apikey|authorization|cookie)"#
        + #"|(?:[A-Za-z0-9]{1,64}[_.-]){0,8}[A-Za-z0-9]{0,64}secret(?:[_.-][A-Za-z0-9]{1,64}){1,4}"#
        + #"|(?:[A-Za-z0-9]{1,64}[_.-]){1,8}(?:key|pass|pwd)"#
        + #"|(?:[A-Za-z0-9]{1,64}[_.-]){0,8}[A-Za-z0-9]{0,64}(?:private|access|secret|signing|encryption|master|client)key"#
        + #"|auth"#

    private static let secretKeyRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^(?:\(secretKeyPattern))$", options: [.caseInsensitive])
    }()

    private static let cliFlagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^-{1,2}(?:\(secretKeyPattern))$", options: [.caseInsensitive])
    }()

    static let authorizationHeader = rule(
        "authorization-header",
        #"(\b(?:proxy-)?authorization\\?["']?[ \t]{0,8}[:=][ \t]{0,8}\\?["']?(?:(?:bearer|basic|token|digest|negotiate)[ \t]{1,8})?)[^\s"'\\,;}]{1,8192}"#,
        .keepFirstGroup, caseInsensitive: true, hints: ["authorization"]
    )

    /// `Cookie:` / `Set-Cookie:` headers carry several `name=value` pairs
    /// split by `;`, so the whole value is masked to the end of the line (or
    /// the closing quote).
    static let cookieHeader = rule(
        "cookie-header",
        #"(\b(?:set-)?cookie\\?["']?[ \t]{0,8}:[ \t]{0,8}(?:\\?["'])?)[^\r\n"'\\]{1,8192}"#,
        .keepFirstGroup, caseInsensitive: true, hints: ["cookie"]
    )

    /// The password in `scheme://user:password@host`; user and host stay.
    static let urlCredentials = rule(
        "url-credentials",
        #"(\b[A-Za-z][A-Za-z0-9+.-]{1,32}://[^\s:/@"'<>]{0,256}:)[^\s@/"'<>]{1,1024}(?=@)"#,
        .keepFirstGroup, hints: ["://"]
    )

    static let bearerToken = rule(
        "bearer",
        #"(\bbearer[ \t]{1,8})[A-Za-z0-9._~+/=-]{16,4096}"#,
        .keepFirstGroup, caseInsensitive: true, hints: ["bearer"]
    )

    static let prefixedTokens: [Rule] = [
        rule("anthropic", #"\bsk-ant-[A-Za-z0-9_-]{20,512}"#, .prefixHint, hints: ["sk-ant-"]),
        rule("openai", #"\bsk-(?=[A-Za-z0-9_-]{0,512}[0-9])[A-Za-z0-9_-]{20,512}"#, .prefixHint, hints: ["sk-"]),
        rule("github", #"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,255}"#, .prefixHint, hints: ["gh"]),
        rule("github-pat", #"\bgithub_pat_[A-Za-z0-9_]{20,255}"#, .prefixHint, hints: ["github_pat_"]),
        rule("slack", #"\bxox[abprs]-[A-Za-z0-9-]{10,255}"#, .prefixHint, hints: ["xox"]),
        rule("aws", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, .prefixHint, hints: ["akia", "asia"]),
        rule("google", #"\bAIza[0-9A-Za-z_-]{35}"#, .prefixHint, hints: ["aiza"]),
        rule("gitlab", #"\bglpat-[A-Za-z0-9_-]{20,255}"#, .prefixHint, hints: ["glpat-"]),
        rule("npm", #"\bnpm_[A-Za-z0-9]{36}\b"#, .prefixHint, hints: ["npm_"]),
        rule("stripe", #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,255}"#, .prefixHint, hints: ["_live_", "_test_"]),
        rule("jwt", #"\beyJ[A-Za-z0-9_-]{7,4096}\.[A-Za-z0-9_-]{10,4096}\.[A-Za-z0-9_-]{10,4096}"#, .prefixHint, hints: ["eyj"]),
    ]

    /// `key = value`, `key: value`, `"key": "value"`, `export KEY=value`.
    /// The regex takes the whole key token once (possessive, no retries
    /// inside it) and `secretKeyEnds` classifies it: trying the key pattern
    /// at every `-` or `.` in the text was several times slower. The value
    /// (group 2) is read ahead, not consumed, so a key that isn't secret
    /// leaves its value to be scanned (`--build-arg=NPM_TOKEN=abc`).
    static let keyedValue = rule(
        "keyed-value",
        #"((?<![A-Za-z0-9_.-])[A-Za-z0-9_.-]{1,4096}+\\?["']?[ \t]{0,8}[:=][ \t]{0,8})"#
            + #"(?=(\\?"([^"\\\r\n]{1,4096})|'([^'\r\n]{1,4096})'|([^\s"'\\,;&}\]\)\[{]{1,4096})))"#,
        .keyedValue, caseInsensitive: true, hints: keyHints
    )

    /// CLI flags: `--token value`, `-api-key value`.
    static let cliFlagValue = rule(
        "cli-flag",
        #"((?<![A-Za-z0-9_.-])-[A-Za-z0-9_.-]{1,4096}+[ \t]{1,8})"#
            + #"(?=("([^"\r\n]{1,4096})"|'([^'\r\n]{1,4096})'|([^\s"'\\,;&}\]\)\[{-][^\s"'\\,;&}\]\)\[{]{0,4095})))"#,
        .flagValue, caseInsensitive: true, hints: keyHints
    )

    private static let keyHints = ["pass", "pwd", "secret", "token", "key", "auth", "cookie"]

    static let allRules: [Rule] = [authorizationHeader, cookieHeader, bearerToken, urlCredentials, puttyPrivateLines]
        + prefixedTokens + [keyedValue, cliFlagValue]
    /// Prose keeps sentences like "Set the cookie: …" intact, so the cookie
    /// header rule and keyed values are left out.
    static let proseRules: [Rule] = [authorizationHeader, bearerToken, urlCredentials, puttyPrivateLines] + prefixedTokens

    /// PEM and PGP armor (`-----BEGIN PGP PRIVATE KEY BLOCK-----`).
    private static let pemBegin: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----"#)
    }()

    private static let pemEnd: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"-----END [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----"#)
    }()

    /// A PuTTY key file's private section: the count line stays, the
    /// base64 lines after it are masked.
    static let puttyPrivateLines = rule(
        "putty-private",
        #"(Private-Lines:[ \t]{0,8}[0-9]{1,4}\r?\n)[A-Za-z0-9+/=]{1,128}(?=\r?\n|$)(?:\r?\n[A-Za-z0-9+/=]{1,128}(?=\r?\n|$)){0,511}"#,
        .keepFirstGroup, hints: ["private-lines"]
    )

    // MARK: Masking

    static func mask(_ text: String, rules: [Rule]) -> (text: String, redacted: Bool) {
        guard !text.isEmpty else { return (text, false) }
        var current = text
        var redacted = false
        if current.contains("-----BEGIN") || current.contains("-----END") {
            let pem = maskPEM(current)
            current = pem.text
            redacted = redacted || pem.redacted
        }
        let lowered = current.lowercased()
        for rule in rules where rule.hints.isEmpty || rule.hints.contains(where: lowered.contains) {
            let result = apply(rule, to: current)
            if result.redacted {
                current = result.text
                redacted = true
            }
        }
        return (current, redacted)
    }

    /// Keeps the BEGIN/END armor and masks the body; an unterminated BEGIN
    /// masks through the end of the text, and an END with no BEGIN before
    /// it (a tail cut inside a key) masks the base64 lines directly above it.
    private static func maskPEM(_ text: String) -> (text: String, redacted: Bool) {
        let source = text as NSString
        let output = NSMutableString()
        var cursor = 0
        var redacted = false
        if let end = pemEnd.firstMatch(in: text, range: NSRange(location: 0, length: source.length)),
           pemBegin.firstMatch(in: text, range: NSRange(location: 0, length: end.range.location)) == nil,
           let body = orphanArmorBody(source, before: end.range.location) {
            output.append(source.substring(to: body))
            output.append("\(maskText)\n")
            output.append(source.substring(with: end.range))
            cursor = end.range.upperBound
            redacted = true
        }
        while cursor < source.length,
              let begin = pemBegin.firstMatch(in: text, range: NSRange(location: cursor, length: source.length - cursor)) {
            redacted = true
            output.append(source.substring(with: NSRange(location: cursor, length: begin.range.upperBound - cursor)))
            output.append("\n\(maskText)\n")
            let after = begin.range.upperBound
            guard let end = pemEnd.firstMatch(in: text, range: NSRange(location: after, length: source.length - after)) else {
                cursor = source.length
                break
            }
            output.append(source.substring(with: end.range))
            cursor = end.range.upperBound
        }
        if cursor < source.length { output.append(source.substring(from: cursor)) }
        return (output as String, redacted)
    }

    /// Where the run of armor body lines (base64, with blank lines between)
    /// ending at `location` starts; nil unless the END starts its line and at
    /// least one such line sits directly above it. Unrelated text above the
    /// run (a command, earlier output) stays.
    private static func orphanArmorBody(_ source: NSString, before location: Int) -> Int? {
        guard location > 0, source.character(at: location - 1) == 0x0A else { return nil }
        var (start, body, lines) = (location, nil as Int?, 0)
        while start > 0, lines < 1_024 {
            lines += 1
            let line = source.lineRange(for: NSRange(location: start - 1, length: 0))
            let text = source.substring(with: line).trimmingCharacters(in: .newlines)
            if text.range(of: #"^[A-Za-z0-9+/=]{1,128}$"#, options: .regularExpression) != nil {
                body = line.location
            } else if !text.isEmpty {
                break
            }
            start = line.location
        }
        return body
    }

    private static func apply(_ rule: Rule, to text: String) -> (text: String, redacted: Bool) {
        let source = text as NSString
        let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, false) }
        let output = NSMutableString()
        var cursor = 0
        var redacted = false
        for match in matches where match.range.location >= cursor {
            let span = replacedSpan(match)
            guard let replacement = replacement(for: match, span: span, rule: rule, in: source) else { continue }
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            output.append(replacement)
            cursor = span.upperBound
            redacted = true
        }
        guard redacted else { return (text, false) }
        output.append(source.substring(from: cursor))
        return (output as String, true)
    }

    /// The match plus any value read ahead of it (keyed rules' group 2).
    private static func replacedSpan(_ match: NSTextCheckingResult) -> NSRange {
        let upper = (0..<match.numberOfRanges).map { match.range(at: $0) }.filter { $0.location != NSNotFound }.map(NSMaxRange).max()
        return NSRange(location: match.range.location, length: (upper ?? match.range.upperBound) - match.range.location)
    }

    private static func replacement(for match: NSTextCheckingResult, span: NSRange, rule: Rule, in source: NSString) -> String? {
        let matched = source.substring(with: span)
        guard !matched.contains("•") else { return nil }
        switch rule.replacement {
        case .whole:
            return maskText
        case .keepFirstGroup:
            return source.substring(with: match.range(at: 1)) + maskText
        case .prefixHint:
            return matched.count >= 16 ? String(matched.prefix(4)) + maskText : maskText
        case .keyedValue, .flagValue:
            guard secretKeyEnds(source.substring(with: match.range(at: 1)), flag: rule.replacement == .flagValue) else {
                return nil
            }
            return keyedReplacement(for: match, in: source)
        }
    }

    /// True when the key token opening `prefix` ends in a secret key name:
    /// the whole token, or its part after a `-` or `.` (`x.token`,
    /// `--db-password`). The key pattern allows at most 12 separators, so
    /// only the last 13 can start one.
    private static func secretKeyEnds(_ prefix: String, flag: Bool) -> Bool {
        let token = Array(prefix.unicodeScalars.prefix { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil
                                                                        || "_.-".unicodeScalars.contains($0)) })
        var separators = 0
        for start in stride(from: token.count - 1, through: 0, by: -1) {
            let previous = start > 0 ? token[start - 1] : nil
            let opens = flag ? token[start] == "-" && (previous == nil || previous == ".") : previous == nil || previous == "-" || previous == "."
            if opens {
                let key = String(String.UnicodeScalarView(token[start...]))
                if flag ? isSecretFlag(key) : isSecretKey(key) { return true }
            }
            if "_.-".unicodeScalars.contains(token[start]) { separators += 1 }
            if separators > 14 { return false }
        }
        return false
    }

    private static func keyedReplacement(for match: NSTextCheckingResult, in source: NSString) -> String? {
        let key = source.substring(with: match.range(at: 1))
        if match.range(at: 3).location != NSNotFound {
            let value = source.substring(with: match.range(at: 3))
            // Keep the opening quote (and its escape) so JSON stays well formed.
            let opening = source.substring(with: NSRange(
                location: match.range(at: 1).upperBound,
                length: match.range(at: 3).location - match.range(at: 1).upperBound
            ))
            return value.contains("•") ? nil : key + opening + maskText
        }
        if match.range(at: 4).location != NSNotFound {
            return key + "'" + maskText + "'"
        }
        guard match.range(at: 5).location != NSNotFound else { return nil }
        let value = source.substring(with: match.range(at: 5))
        return isLiteral(value) ? nil : key + maskText
    }

    /// Unquoted values that aren't secrets: numbers, booleans, null, and
    /// shell/env references.
    private static func isLiteral(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if ["true", "false", "null", "nil", "none", "yes", "no"].contains(lowered) { return true }
        // An Authorization scheme word: the header rule already masked its credential.
        if ["bearer", "basic", "token", "digest", "negotiate"].contains(lowered) { return true }
        if value.hasPrefix("$") || value.hasPrefix("%") { return true }
        return Double(value) != nil
    }

    // MARK: JSON

    static func isSecretKey(_ key: String) -> Bool {
        secretKeyRegex.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
    }

    private static func isSecretFlag(_ text: String) -> Bool {
        text.hasPrefix("-") && text.count <= 600
            && cliFlagRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func redactJSON(_ value: JSONValue, redacted: inout Bool) -> JSONValue {
        switch value {
        case .string(let text):
            let masked = mask(text, rules: allRules)
            if masked.redacted { redacted = true }
            return .string(masked.text)
        case .array(let elements):
            var result: [JSONValue] = []
            result.reserveCapacity(elements.count)
            var maskNext = false
            for element in elements {
                if maskNext, case .string(let text) = element, !text.isEmpty {
                    result.append(.string(maskText))
                    redacted = true
                    maskNext = false
                    continue
                }
                maskNext = false
                if case .string(let text) = element, isSecretFlag(text) { maskNext = true }
                result.append(redactJSON(element, redacted: &redacted))
            }
            return .array(result)
        case .object(let object):
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(object.count)
            for (key, child) in object {
                // A key can itself be a secret (a token used as a map key).
                let maskedKey = mask(key, rules: allRules)
                if maskedKey.redacted { redacted = true }
                if case .string(let text) = child, !text.isEmpty, isSecretKey(key) {
                    result[maskedKey.text] = .string(maskText)
                    redacted = true
                } else {
                    result[maskedKey.text] = redactJSON(child, redacted: &redacted)
                }
            }
            return .object(result)
        case .null, .bool, .number:
            return value
        }
    }

    // MARK: Text shaping

    /// The first `maximumLines` lines and how many were dropped. A trailing
    /// newline doesn't start a new line.
    static func truncateLines(_ text: String, maximumLines: Int) -> (String, Int) {
        let utf8 = text.utf8
        var newlines = 0
        var cut: String.Index?
        for index in utf8.indices where utf8[index] == 0x0A {
            newlines += 1
            if newlines == maximumLines { cut = index }
        }
        let lineCount = text.isEmpty ? 0 : newlines + (utf8.last == 0x0A ? 0 : 1)
        guard lineCount > maximumLines else { return (text, 0) }
        guard maximumLines > 0, let cut else { return ("", lineCount) }
        var kept = String(text[..<cut])
        if kept.hasSuffix("\r") { kept.removeLast() }
        return (kept, lineCount - maximumLines)
    }

    /// Folds controls and line breaks into single spaces and escapes bidi
    /// overrides (`\u{202E}`), trimming the ends.
    static func singleLine(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if isBidiControl(scalar) {
                output.append(contentsOf: escaped(scalar).unicodeScalars)
                lastWasSpace = false
            } else if scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
                        || scalar.properties.isWhitespace {
                if !lastWasSpace { output.append(" ") }
                lastWasSpace = true
            } else {
                output.append(scalar)
                lastWasSpace = false
            }
        }
        var result = String(output)
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Escapes control characters (keeping newlines and tabs), bidi
    /// overrides, and invisible format characters (zero-width spaces, tag
    /// characters) so tooltips and approval text show exactly what will run.
    static func escapeControls(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                output.append(scalar)
            } else if isBidiControl(scalar) || scalar.properties.generalCategory == .control
                        || scalar.properties.generalCategory == .format
                        || scalar == "\u{2028}" || scalar == "\u{2029}" {
                output.append(contentsOf: escaped(scalar).unicodeScalars)
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }

    static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
    }
}
