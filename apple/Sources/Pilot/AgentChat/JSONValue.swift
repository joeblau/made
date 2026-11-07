import Foundation

/// A JSON document exchanged with a coding agent.
///
/// ACP messages are open-ended — agents add `_meta` fields and new update kinds
/// freely — so the client parses into this tree and reads only the fields it
/// understands instead of failing on shapes it has never seen.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

enum JSONValueError: Error, Equatable {
    case nestingTooDeep(limit: Int)
    case unsupportedValue
}

extension JSONValue {
    /// Bounds recursion on untrusted input before any value is materialized.
    static let maximumDepth = 64

    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONValue(foundationObject: object, depth: 0)
    }

    func serialized() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: foundationObject,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
    }

    private init(foundationObject object: Any, depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw JSONValueError.nestingTooDeep(limit: Self.maximumDepth) }
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // JSONSerialization reports booleans as CFBoolean-backed NSNumbers.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map { try JSONValue(foundationObject: $0, depth: depth + 1) })
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues { try JSONValue(foundationObject: $0, depth: depth + 1) })
        default:
            throw JSONValueError.unsupportedValue
        }
    }

    private var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                NSNumber(value: Int64(value))
            } else {
                NSNumber(value: value)
            }
        case .string(let value): value
        case .array(let values): values.map(\.foundationObject)
        case .object(let values): values.mapValues(\.foundationObject)
        }
    }
}

// MARK: - Accessors

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    /// Integral numbers only; fractional or out-of-range values return nil.
    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// The first integral value among `keys`, so callers can accept both the
    /// camelCase and snake_case spellings agents use for the same field.
    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let value = self[key]?.intValue { return value }
        }
        return nil
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Bounds

extension JSONValue {
    /// Approximate compact-JSON size in bytes, measured by a tree walk with no
    /// serialization. The walk stops as soon as the running total passes
    /// `limit`, so the result is exact only up to `limit`: anything larger
    /// means "over".
    func estimatedByteCount(limit: Int = .max) -> Int {
        var total = 0
        accumulateByteCount(into: &total, limit: limit)
        return total
    }

    private func accumulateByteCount(into total: inout Int, limit: Int) {
        switch self {
        case .null: total += 4
        case .bool(let value): total += value ? 4 : 5
        case .number(let value): total += Self.estimatedDigits(value)
        case .string(let value): total += value.utf8.count + 2
        case .array(let values):
            total += 2
            for (index, value) in values.enumerated() {
                total += index > 0 ? 1 : 0
                guard total <= limit else { return }
                value.accumulateByteCount(into: &total, limit: limit)
            }
        case .object(let values):
            total += 2
            for (index, (key, value)) in values.enumerated() {
                total += key.utf8.count + (index > 0 ? 4 : 3)
                guard total <= limit else { return }
                value.accumulateByteCount(into: &total, limit: limit)
            }
        }
    }

    private static func estimatedDigits(_ value: Double) -> Int {
        guard value.rounded() == value, abs(value) < 1e15 else { return 24 }
        var magnitude = abs(value)
        var digits = value < 0 ? 2 : 1
        while magnitude >= 10 {
            magnitude /= 10
            digits += 1
        }
        return digits
    }

    /// Compact JSON text with sorted keys, cut at `maximumBytes` UTF-8 bytes.
    /// Stops walking once the budget is spent, so a huge value costs no more
    /// than the prefix it keeps.
    func boundedRendering(maximumBytes: Int) -> String {
        var renderer = BoundedJSONRenderer(remaining: max(maximumBytes, 0))
        renderer.write(self)
        return renderer.output
    }
}

private struct BoundedJSONRenderer {
    var remaining: Int
    var output = ""

    mutating func write(_ value: JSONValue) {
        guard remaining > 0 else { return }
        switch value {
        case .null: append("null")
        case .bool(let flag): append(flag ? "true" : "false")
        case .number(let number):
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                append(String(Int64(number)))
            } else {
                append(String(number))
            }
        case .string(let text): writeString(text)
        case .array(let values):
            append("[")
            for (index, element) in values.enumerated() {
                guard remaining > 0 else { return }
                if index > 0 { append(",") }
                write(element)
            }
            append("]")
        case .object(let values):
            append("{")
            for (index, key) in values.keys.sorted().enumerated() {
                guard remaining > 0, let element = values[key] else { return }
                if index > 0 { append(",") }
                writeString(key)
                append(":")
                write(element)
            }
            append("}")
        }
    }

    /// Escaping only grows text, so the raw prefix that fits is escaped, never the whole string.
    private mutating func writeString(_ text: String) {
        let raw = text.utf8Prefix(remaining)
        var escaped = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20:
                escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        append(escaped + "\"")
    }

    private mutating func append(_ text: String) {
        let count = text.utf8.count
        if count <= remaining {
            output += text
            remaining -= count
        } else {
            output += text.utf8Prefix(remaining)
            remaining = 0
        }
    }
}

extension String {
    /// The longest prefix whose UTF-8 encoding fits in `maximumBytes`, cut at
    /// a character boundary.
    func utf8Prefix(_ maximumBytes: Int) -> String {
        guard utf8.count > maximumBytes else { return self }
        guard maximumBytes > 0 else { return "" }
        var end = utf8.index(utf8.startIndex, offsetBy: maximumBytes)
        while end > startIndex, end.samePosition(in: self) == nil {
            end = utf8.index(before: end)
        }
        return String(self[..<end])
    }

    /// The longest suffix whose UTF-8 encoding fits in `maximumBytes`, cut at
    /// a character boundary.
    func utf8Suffix(_ maximumBytes: Int) -> String {
        guard utf8.count > maximumBytes else { return self }
        guard maximumBytes > 0 else { return "" }
        var start = utf8.index(utf8.endIndex, offsetBy: -maximumBytes)
        while start < endIndex, start.samePosition(in: self) == nil {
            start = utf8.index(after: start)
        }
        return String(self[start...])
    }

    /// `utf8Suffix`, and when that cut text, without the partial first line
    /// (or, in one long line, the partial first word): a secret cut in half
    /// loses the key, prefix, or armor its redaction rule needs, so its
    /// remainder is dropped rather than shown.
    func utf8SuffixAtLineBoundary(_ maximumBytes: Int) -> String {
        let tail = utf8Suffix(maximumBytes)
        guard tail.utf8.count < utf8.count else { return tail }
        if let newline = tail.firstIndex(where: \.isNewline) { return String(tail[tail.index(after: newline)...]) }
        if let space = tail.firstIndex(where: \.isWhitespace) { return String(tail[tail.index(after: space)...]) }
        return tail
    }

    /// Nil when empty; otherwise at most `maximumBytes` UTF-8 bytes.
    func boundedNonEmpty(_ maximumBytes: Int) -> String? {
        isEmpty ? nil : utf8Prefix(maximumBytes)
    }
}

// MARK: - Step payload sizing and diff counting

extension AgentTranscript {
    /// Per-file edit counts from diff blocks, merged by path in first-seen
    /// order. A diff cut to fit the block budget gets no counts.
    static func edits(blocks: [ACPToolContent], truncatedPaths: Set<String>) -> [AgentEditSummary] {
        var order: [String] = []
        var byPath: [String: AgentEditSummary] = [:]
        for case .diff(let path, let oldText, let newText) in blocks {
            let counts = truncatedPaths.contains(path) ? nil : lineChanges(old: oldText ?? "", new: newText)
            if var summary = byPath[path] {
                summary.added = summary.added.flatMap { added in counts.map { added + $0.added } }
                summary.removed = summary.removed.flatMap { removed in counts.map { removed + $0.removed } }
                byPath[path] = summary
            } else {
                order.append(path)
                byPath[path] = AgentEditSummary(
                    path: path, added: counts?.added, removed: counts?.removed, created: oldText == nil
                )
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// Lines added and removed as multiset differences (added = new − old,
    /// removed = old − new): O(n), order-insensitive. Nil past 20k lines on a side.
    static func lineChanges(old: String, new: String) -> (added: Int, removed: Int)? {
        guard let oldLines = lines(old), let newLines = lines(new) else { return nil }
        var remaining: [Substring: Int] = [:]
        remaining.reserveCapacity(oldLines.count)
        for line in oldLines { remaining[line, default: 0] += 1 }
        var added = 0
        for line in newLines {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
            } else {
                added += 1
            }
        }
        return (added, remaining.values.reduce(0, +))
    }

    private static func lines(_ text: String) -> [Substring]? {
        guard !text.isEmpty else { return [] }
        var count = 1
        for byte in text.utf8 where byte == UInt8(ascii: "\n") {
            count += 1
            if count > maximumDiffLines + 1 { return nil }
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines.count > maximumDiffLines ? nil : lines
    }

    /// Keeps the newest ≤ 256 KiB; past the cap it trims to three quarters so
    /// streaming does not rebuild the buffer on every chunk.
    static func appendTerminal(_ delta: String, to output: inout String) {
        let cap = ACPBounds.terminalOutputBytes
        guard output.utf8.count + delta.utf8.count > cap else {
            output += delta
            return
        }
        let marker = terminalTruncationMarker
        let tail = (output + delta).utf8SuffixAtLineBoundary(cap * 3 / 4 - marker.utf8.count)
        output = marker + tail
    }

    static func retainedBytes(_ detail: AgentStepDetail) -> Int {
        var bytes = (detail.rawInput?.retainedBytes ?? 0) + (detail.rawOutput?.retainedBytes ?? 0)
        bytes += detail.terminalOutput.utf8.count
        for block in detail.blocks {
            switch block {
            case .text(let text): bytes += text.utf8.count
            case .diff(let path, let oldText, let newText):
                bytes += path.utf8.count + (oldText?.utf8.count ?? 0) + newText.utf8.count
            case .terminal(let id): bytes += id.utf8.count
            case .other(let type): bytes += type.utf8.count
            }
        }
        return bytes
    }
}
