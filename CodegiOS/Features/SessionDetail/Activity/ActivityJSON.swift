import Foundation

/// Lenient readers for tool-call payloads — port of the web's
/// `src/lib/activity/json.ts` (codeg 0.44).
///
/// Agents hand tool input and output over as strings that are usually JSON,
/// sometimes truncated JSON, and occasionally plain text, with the interesting
/// field buried one or two envelopes deep (`{input: {...}}`, `{arguments:
/// "..."}`). These pull a value out of whatever arrived without throwing on any
/// of those shapes.
///
/// Values are `JSONSerialization` objects (`[String: Any]`, `[Any]`, `String`,
/// `NSNumber`, `NSNull`). A JSON boolean arrives as an `NSNumber` too, so every
/// "is this a number" test here excludes booleans — `typeof v === "number"` is
/// false for `true` in JavaScript.
enum ActivityJSON {
    /// Parse `s` as JSON; nil on failure or when the value is not an object.
    static func tryParse(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return value as? [String: Any]
    }

    /// Parse any JSON value (object, array, scalar); nil on failure.
    static func parseValue(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Regex-extract a JSON string value for a given key — works on truncated
    /// JSON, where a parse fails.
    static func extractField(_ input: String, key: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let re = try? NSRegularExpression(pattern: "\"\(escaped)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"") else { return nil }
        let ns = input as NSString
        guard let m = re.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// The value as an object: itself when it already is one, or a string that
    /// parses to one (only when it starts with `{` after trimming).
    static func asObjectLike(_ value: Any?) -> [String: Any]? {
        if let obj = value as? [String: Any] { return obj }
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        return tryParse(trimmed)
    }

    private static let nestedPayloadKeys = ["input", "arguments", "params", "payload"]

    /// A non-blank string at `key`, searched through the usual envelopes first
    /// and then every nested value, at most 4 levels deep.
    static func findStringFieldDeep(_ value: Any?, key: String, depth: Int = 0) -> String? {
        if depth > 4 { return nil }
        if let array = value as? [Any] {
            for item in array {
                if let found = findStringFieldDeep(item, key: key, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let obj = asObjectLike(value) else { return nil }
        if let direct = obj[key] as? String,
           !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return direct
        }
        for nested in nestedPayloadKeys {
            if let found = findStringFieldDeep(obj[nested], key: key, depth: depth + 1) { return found }
        }
        for (_, nestedValue) in orderedEntries(obj) {
            if let found = findStringFieldDeep(nestedValue, key: key, depth: depth + 1) { return found }
        }
        return nil
    }

    /// An object at `key`, searched like ``findStringFieldDeep(_:key:depth:)``.
    static func findObjectFieldDeep(_ value: Any?, key: String, depth: Int = 0) -> [String: Any]? {
        if depth > 4 { return nil }
        if let array = value as? [Any] {
            for item in array {
                if let found = findObjectFieldDeep(item, key: key, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let obj = asObjectLike(value) else { return nil }
        if let direct = asObjectLike(obj[key]) { return direct }
        for nested in nestedPayloadKeys {
            if let found = findObjectFieldDeep(obj[nested], key: key, depth: depth + 1) { return found }
        }
        for (_, nestedValue) in orderedEntries(obj) {
            if let found = findObjectFieldDeep(nestedValue, key: key, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Undo the escapes a JSON string literal carries, for text pulled out of
    /// JSON by regex rather than by a parser.
    static func decodeEscapedString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// String field of a parsed object.
    static func str(_ obj: [String: Any], _ key: String) -> String? {
        obj[key] as? String
    }

    /// Number field of a parsed object — never a boolean.
    static func num(_ obj: [String: Any], _ key: String) -> Double? {
        number(obj[key])
    }

    /// A JSON number as a Double — nil for booleans, strings and everything else.
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
        return n.doubleValue
    }

    /// A JSON integer (a number with no fractional part).
    static func int(_ value: Any?) -> Int? {
        guard let d = number(value), d.isFinite, d == d.rounded(),
              abs(d) < Double(Int.max) else { return nil }
        return Int(d)
    }

    static func isBoolean(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func isLikelyIdField(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "id" || lower == "uuid" || lower == "callid" || lower == "call_id"
            || lower == "tool_call_id" || lower.hasSuffix("_id") || lower.hasSuffix("id")
    }

    /// An object's entries in a stable order. JavaScript walks an object in
    /// insertion order; a `JSONSerialization` dictionary has none, so the deep
    /// searches fall back to key order — deterministic, which is what matters
    /// when two nested values could both answer.
    static func orderedEntries(_ obj: [String: Any]) -> [(String, Any)] {
        obj.keys.sorted().map { ($0, obj[$0]!) }
    }
}
