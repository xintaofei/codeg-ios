import Foundation

/// The payload an MCP result carries once the host and protocol layers are
/// off (web `McpResultPayload`).
struct McpResultPayload: Equatable, Hashable, Sendable {
    /// The structured result (an object or array) when there is one.
    var json: AnyJSON?
    /// The result as text, when it is not structured.
    var text: String?
    /// The server marked the result as an error (`CallToolResult.isError`).
    var isError: Bool
}

/// Third-party MCP tool calls: who served them and what they were about —
/// port of the web's `src/lib/activity/mcp.ts` (codeg 0.44).
///
/// Hosts spell an MCP tool's identity differently — Claude Code, Kiro, Qoder and
/// codex's rollout write `mcp__<server>__<tool>`, codex's live stream
/// `<server>/<tool>`, others `<server>.<tool>` or `<server>:<tool>`. The server
/// half is what the row's source chip shows; the tool half is the row's name.
/// codeg's own companion tools never get here: they are resolved to their
/// canonical names (and dedicated rows) before this is consulted.
enum ActivityMcp {
    /// Prefixes that look like `<server>.<tool>` but are not MCP servers.
    private static let nonMcpPrefixes: Set<String> = ["functions", "multi_tool_use", "tools"]

    // JS `.` (no `s` flag) stops only at \n \r \u2028 \u2029; ICU's also stops at
    // \v \f \u0085, so spell the JS class out. JS `\w` (no `u` flag) is ASCII,
    // ICU's is Unicode — also spelled out. `\z` is JS's `$` without `m`.
    private static let doubleUnderscoreRe = try! NSRegularExpression(
        pattern: #"^mcp__([^\n\r\u2028\u2029]+?)__([^\n\r\u2028\u2029]+)\z"#,
        options: [.caseInsensitive]
    )
    private static let separatedRe = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9][A-Za-z0-9_-]*)[/.:]([A-Za-z0-9][A-Za-z0-9_.-]*)\z"#
    )

    static func parseMcpToolName(_ rawName: String) -> McpIdentity? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let groups = captures(doubleUnderscoreRe, name) {
            let server = groups[0], tool = groups[1]
            if server.isEmpty || tool.isEmpty { return nil }
            return McpIdentity(server: server, tool: tool)
        }
        if let groups = captures(separatedRe, name) {
            let server = groups[0], tool = groups[1]
            if nonMcpPrefixes.contains(server.lowercased()) { return nil }
            return McpIdentity(server: server, tool: tool)
        }
        return nil
    }

    static let maxArgPreview = 60
    static let maxResultPreview = 80
    /// Result fields that name what came back, in order of preference.
    private static let resultLabelKeys = ["title", "name", "summary", "message"]

    /// The first argument worth naming the call by: `{id: "HVAC-212"}` → "HVAC-212".
    ///
    /// "First" is the object's source order, as JavaScript's `Object.values`
    /// walks it — recovered from the input text, since a `JSONSerialization`
    /// dictionary has none.
    static func mcpArgumentPreview(_ input: String?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        guard let parsed = ActivityJSON.tryParse(input) else {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !text.hasPrefix("{")
                ? ActivityFormat.ellipsis(text, maxArgPreview)
                : nil
        }
        for value in jsObjectValues(parsed, source: input) {
            if let string = value as? String {
                let text = collapseWhitespace(string)
                if !text.isEmpty { return ActivityFormat.ellipsis(text, maxArgPreview) }
            } else if let number = ActivityJSON.number(value), number.isFinite {
                return jsNumberString(number)
            }
        }
        return nil
    }

    /// The payload an MCP result carries, with the host and protocol layers taken
    /// off: codex's `{result, error}` / `{Ok}` envelopes, then the `CallToolResult`
    /// itself — its `structuredContent` when present (that is what the model saw),
    /// else its text blocks, parsed as JSON when they are JSON.
    static func mcpResultPayload(_ output: String?) -> McpResultPayload? {
        guard let output else { return nil }
        guard let parsed = parseJsonValue(output) else {
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : McpResultPayload(json: nil, text: output, isError: false)
        }
        guard let object = parsed as? [String: Any] else {
            if let array = parsed as? [Any], let text = textOfContent(array) {
                if let inner = parseJsonValue(text) {
                    return McpResultPayload(json: AnyJSON(any: inner), text: nil, isError: false)
                }
                return McpResultPayload(json: nil, text: text, isError: false)
            }
            return McpResultPayload(json: AnyJSON(any: parsed), text: nil, isError: false)
        }
        let peeled = McpResultEnvelope.peel(object, isResolvable: isCallToolResult)
        if let hostError = peeled.hostError {
            return McpResultPayload(json: nil, text: hostError, isError: true)
        }
        let obj = peeled.obj
        if !isCallToolResult(obj) {
            return McpResultPayload(json: AnyJSON(any: obj), text: nil, isError: false)
        }
        let isError = isTrue(obj["isError"])
        // `structured && typeof structured === "object"`: an array counts too.
        if let structured = obj["structuredContent"], structured is [String: Any] || structured is [Any] {
            return McpResultPayload(json: AnyJSON(any: structured), text: nil, isError: isError)
        }
        let text = (obj["content"] as? [Any]).flatMap(textOfContent)
        guard let text else {
            return McpResultPayload(json: AnyJSON(any: obj), text: nil, isError: isError)
        }
        if let inner = parseJsonValue(text) {
            return McpResultPayload(json: AnyJSON(any: inner), text: nil, isError: isError)
        }
        return McpResultPayload(json: nil, text: text, isError: isError)
    }

    /// What the result was about: its `title` / `name` / `summary` / `message`.
    static func mcpResultLabel(_ payload: McpResultPayload?) -> String? {
        guard case .object(let record)? = payload?.json else { return nil }
        for key in resultLabelKeys {
            if case .string(let value)? = record[key] {
                let text = collapseWhitespace(value)
                if !text.isEmpty { return ActivityFormat.ellipsis(text, maxResultPreview) }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func isCallToolResult(_ value: [String: Any]) -> Bool {
        value["content"] is [Any] || value["structuredContent"] is [String: Any]
    }

    /// `value === true` — a JSON boolean, never the number 1.
    private static func isTrue(_ value: Any?) -> Bool {
        guard ActivityJSON.isBoolean(value), let n = value as? NSNumber else { return false }
        return n.boolValue
    }

    private static func textOfContent(_ content: [Any]) -> String? {
        let texts = content.compactMap { item -> String? in
            guard let block = item as? [String: Any],
                  block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// JSON parse of a text that opens like an object or array; nil (the web's
    /// `undefined`) for anything else or a failed parse.
    private static func parseJsonValue(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return ActivityJSON.parseValue(trimmed)
    }

    /// `value.replace(/\s+/g, " ").trim()`.
    private static func collapseWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func captures(_ re: NSRegularExpression, _ text: String) -> [String]? {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    // MARK: - JavaScript object order and number formatting

    /// An object's values in the order JavaScript's `Object.values` yields them:
    /// array-index keys ascending, then every other key in first-appearance
    /// order. The order comes from scanning `source`, the text `obj` was parsed
    /// from; keys the scan missed (none, for valid JSON) follow sorted.
    static func jsObjectValues(_ obj: [String: Any], source: String) -> [Any] {
        jsObjectKeys(obj, source: source).compactMap { obj[$0] }
    }

    /// The keys of `obj` in JavaScript's `Object.keys` order (see
    /// ``jsObjectValues(_:source:)``).
    static func jsObjectKeys(_ obj: [String: Any], source: String) -> [String] {
        let scanned = topLevelKeys(source)
        var seen = Set<String>()
        var indexKeys: [(UInt32, String)] = []
        var namedKeys: [String] = []
        for key in scanned where obj[key] != nil && seen.insert(key).inserted {
            if let index = arrayIndex(key) { indexKeys.append((index, key)) } else { namedKeys.append(key) }
        }
        for key in obj.keys.sorted() where seen.insert(key).inserted {
            if let index = arrayIndex(key) { indexKeys.append((index, key)) } else { namedKeys.append(key) }
        }
        return indexKeys.sorted { $0.0 < $1.0 }.map(\.1) + namedKeys
    }

    /// A canonical array index (`"0"`, `"12"`, below 2³²−1), which JavaScript
    /// enumerates before string keys.
    private static func arrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              key == "0" || !key.hasPrefix("0"),
              let value = UInt32(key), value < UInt32.max else { return nil }
        return value
    }

    /// The keys of the top-level object in `source`, in the order they appear,
    /// each decoded as JSON decodes it (escapes resolved).
    private static func topLevelKeys(_ source: String) -> [String] {
        let units = Array(source.utf16)
        let quote: UInt16 = 0x22, backslash: UInt16 = 0x5C
        var i = 0
        while i < units.count, units[i] != 0x7B /* { */ { i += 1 }
        guard i < units.count else { return [] }
        i += 1
        var keys: [String] = []
        var depth = 0
        var expectKey = true
        while i < units.count {
            let c = units[i]
            if c == quote {
                let start = i + 1
                i = start
                while i < units.count, units[i] != quote {
                    i += units[i] == backslash ? 2 : 1
                }
                if depth == 0, expectKey, i <= units.count {
                    let literal = [quote] + units[start..<min(i, units.count)] + [quote]
                    if let key = ActivityJSON.parseValue(String(decoding: literal, as: UTF16.self)) as? String {
                        keys.append(key)
                    }
                    expectKey = false
                }
                i += 1
                continue
            }
            switch c {
            case 0x7B, 0x5B: depth += 1 // { [
            case 0x7D, 0x5D: // } ]
                if depth == 0 { return keys }
                depth -= 1
            case 0x2C where depth == 0: expectKey = true // ,
            default: break
            }
            i += 1
        }
        return keys
    }

    /// A finite number as JavaScript's `String(number)` writes it: shortest
    /// round-trip digits, plain notation for exponents in [-7, 21), else
    /// `1.5e+21` / `1e-7`.
    static func jsNumberString(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value < 0 { return "-" + jsNumberString(-value) }
        // Swift's description already holds the shortest round-trip digits.
        let description = "\(value)"
        let parts = description.lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(pieces[0])
        let fracPart = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = Array(intPart + fracPart)
        var point = intPart.count + exponent // value = 0.digits × 10^point
        while let first = digits.first, first == "0" { digits.removeFirst(); point -= 1 }
        while let last = digits.last, last == "0" { digits.removeLast() }
        guard !digits.isEmpty else { return "0" }
        let k = digits.count, n = point
        let all = String(digits)
        if k <= n && n <= 21 {
            return all + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            return String(digits[..<n]) + "." + String(digits[n...])
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + all
        }
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let head = k == 1 ? all : String(digits[0]) + "." + String(digits[1...])
        return "\(head)e\(sign)\(abs(e))"
    }
}
