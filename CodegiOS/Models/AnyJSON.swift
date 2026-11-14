import Foundation

/// A decoded arbitrary JSON value. Holds the freeform `tool_call` blob carried by
/// a `permission_request` event (Rust `serde_json::Value`).
///
/// (Distinct from `JSONValue` in `McpModels.swift`, which is the MCP-spec editor's
/// round-trippable Codable value. This one adds the accessors + raw-key parsing
/// the permission tool-call parser needs.)
///
/// CASING: keys inside a `tool_call` can reach the parser in EITHER case, so never
/// rely on one spelling. The shared decoder is set to `.convertFromSnakeCase`; and a
/// `rawInput` whose value is itself a JSON *string* gets re-parsed with
/// `AnyJSON.parse(jsonString:)` (via `JSONSerialization`, which never converts keys),
/// preserving raw snake_case. `ParsedPermission.parse` therefore probes both
/// snake_case and camelCase for every multi-word key.
enum AnyJSON: Decodable, Hashable, Sendable {
    case object([String: AnyJSON])
    case array([AnyJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([AnyJSON].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: AnyJSON].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    /// Wrap a `JSONSerialization` object graph (keys preserved verbatim).
    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let num as NSNumber:
            // JSONSerialization models both booleans and numbers as NSNumber;
            // CFBoolean is the only reliable discriminator.
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                self = .bool(num.boolValue)
            } else {
                self = .number(num.doubleValue)
            }
        case let arr as [Any]:
            self = .array(arr.map(AnyJSON.init(any:)))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(AnyJSON.init(any:)))
        default:
            self = .null
        }
    }

    /// Parse a raw JSON string (object/array/fragment) without key conversion.
    static func parse(jsonString: String) -> AnyJSON? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return AnyJSON(any: obj)
    }

    // MARK: - Accessors

    var object: [String: AnyJSON]? { if case .object(let o) = self { return o }; return nil }
    var array: [AnyJSON]? { if case .array(let a) = self { return a }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(_ key: String) -> AnyJSON? { object?[key] }

    /// The value as a trimmed, non-empty string — only when it actually is a string.
    var nonEmptyString: String? {
        guard case .string(let s) = self else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Pretty-printed JSON, for the permission card's raw fallback.
    var prettyPrinted: String {
        let any = toAny()
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return String(describing: any) }
        return s
    }

    /// The value as `JSONSerialization` would have produced it (`[String: Any]`,
    /// `[Any]`, `String`, a number, a boolean, `NSNull`) — for the readers
    /// ported from the web, which take untyped JSON.
    var foundationValue: Any { toAny() }

    private func toAny() -> Any {
        switch self {
        case .object(let o): return o.mapValues { $0.toAny() }
        case .array(let a): return a.map { $0.toAny() }
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}
