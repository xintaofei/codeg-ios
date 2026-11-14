import Foundation

/// MCP (Model Context Protocol) server configs installed on the server. Each is
/// enabled for a set of agent "apps" and carries a free-form JSON `spec`.

/// The agent apps an MCP server can be assigned to. A SEPARATE enum from
/// `AgentType` (it's the MCP-specific app set, which also includes `hermes`).
enum McpAppType: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case claudeCode = "claude_code"
    case codex
    case gemini
    case openClaw = "open_claw"
    case openCode = "open_code"
    case cline
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .openClaw: "OpenClaw"
        case .openCode: "OpenCode"
        case .cline: "Cline"
        case .hermes: "Hermes"
        }
    }
}

/// An installed local MCP server (`mcp_scan_local`). `spec` is the raw MCP server
/// definition (stdio/http/sse) kept as free-form JSON; unknown app strings are
/// dropped so one future app type can't fail the whole list decode.
struct LocalMcpServer: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let spec: JSONValue
    let apps: [McpAppType]

    private enum CodingKeys: String, CodingKey { case id, spec, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        spec = try c.decodeIfPresent(JSONValue.self, forKey: .spec) ?? .object([:])
        let rawApps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        apps = rawApps.compactMap(McpAppType.init(rawValue:))
    }
}

/// A minimal JSON value for free-form fields (the MCP server `spec`). Round-trips
/// arbitrary JSON so specs survive load → edit → upsert without a fixed schema.
indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

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
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Pretty-printed JSON text for display/editing in a `TextEditor`.
    var prettyString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Parse JSON text into a value, or nil if it isn't valid JSON.
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    var isObject: Bool { if case .object = self { return true } else { return false } }

    /// Member access for object values (nil for non-objects / missing keys).
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string payload, or nil if this isn't a `.string`.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The array payload, or nil if this isn't an `.array`.
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

private extension String {
    /// The trimmed string, or nil when it's empty after trimming.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension LocalMcpServer {
    /// Canonical transport derived from the spec's `type` (default `stdio`),
    /// collapsing the `streamable-http` aliases to `http` — mirrors the web's
    /// `normalizeMcpType`.
    private var normalizedTransport: String {
        let raw = (spec["type"]?.stringValue?.trimmedNonEmpty ?? "stdio").lowercased()
        if raw.filter({ $0.isLetter || $0.isNumber }) == "streamablehttp" { return "http" }
        return raw
    }

    /// Short transport badge label: `Stdio` / `HTTP` / `SSE`, or the raw type
    /// for anything unrecognized.
    var transportLabel: String {
        switch normalizedTransport {
        case "stdio": return "Stdio"
        case "http": return "HTTP"
        case "sse": return "SSE"
        default: return spec["type"]?.stringValue?.trimmedNonEmpty ?? normalizedTransport
        }
    }

    /// A one-line, identifiable summary of what the server runs: for `stdio` the
    /// `command` + `args`; for remote transports the `url` (the transport itself
    /// is already shown by the badge).
    var specSummary: String {
        if normalizedTransport == "stdio" {
            let command = spec["command"]?.stringValue?.trimmedNonEmpty ?? String(localized: "(missing command)")
            let args = (spec["args"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmedNonEmpty }
            return args.isEmpty ? command : "\(command) \(args.joined(separator: " "))"
        }
        return spec["url"]?.stringValue?.trimmedNonEmpty ?? String(localized: "(missing url)")
    }
}
