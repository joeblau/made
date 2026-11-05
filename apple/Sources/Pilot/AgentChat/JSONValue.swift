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
