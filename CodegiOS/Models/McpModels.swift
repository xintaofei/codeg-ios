import Foundation

/// MCP (Model Context Protocol) server configs installed on the server. Each is
/// enabled for a set of agent "apps" and carries a free-form JSON `spec`.

/// An agent app an MCP server can be assigned to: the server's `McpAppType`,
/// kept as its wire string. A SEPARATE type from `AgentType` (the MCP app set
/// has its own spellings, e.g. `kimi_code`, and includes `hermes`).
///
/// Open rather than an enum on purpose: saving a server means "these apps and
/// no others" (`mcp_upsert_local_server` removes it from every app not
/// listed), so an app this build doesn't know must survive load → edit → save
/// instead of being dropped — dropping it would unassign the server there.
struct McpAppType: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var id: String { rawValue }

    static let claudeCode = McpAppType(rawValue: "claude_code")
    static let codex = McpAppType(rawValue: "codex")
    static let gemini = McpAppType(rawValue: "gemini")
    static let openClaw = McpAppType(rawValue: "open_claw")
    static let openCode = McpAppType(rawValue: "open_code")
    static let cline = McpAppType(rawValue: "cline")
    static let hermes = McpAppType(rawValue: "hermes")
    static let codeBuddy = McpAppType(rawValue: "code_buddy")
    static let kimiCode = McpAppType(rawValue: "kimi_code")
    static let miniMaxCode = McpAppType(rawValue: "minimax_code")
    static let grok = McpAppType(rawValue: "grok")
    static let cursor = McpAppType(rawValue: "cursor")
    static let deepSeek = McpAppType(rawValue: "deepseek")
    static let qoder = McpAppType(rawValue: "qoder")
    static let antigravity = McpAppType(rawValue: "antigravity")
    static let kiro = McpAppType(rawValue: "kiro")
    static let zCode = McpAppType(rawValue: "zcode")
    static let trae = McpAppType(rawValue: "trae")
    static let commandCode = McpAppType(rawValue: "command_code")
    static let pi = McpAppType(rawValue: "pi")

    /// The apps offered as toggles, in the web's order and with its labels
    /// (`mcp-settings.tsx` `APP_OPTIONS`). OpenClaw and pi are scanned but not
    /// offered: OpenClaw no longer takes MCP over the ACP wire, and pi's MCP
    /// file belongs to a third-party extension. An existing assignment to
    /// either is kept on save (see `McpAppSelection.apps`).
    static let assignable: [McpAppType] = [
        .claudeCode, .codex, .gemini, .openCode, .cline, .hermes, .codeBuddy,
        .kimiCode, .miniMaxCode, .grok, .cursor, .deepSeek, .qoder, .antigravity,
        .kiro, .zCode, .trae, .commandCode,
    ]

    /// Product name; an app this build doesn't know shows its wire value.
    var displayName: String {
        switch rawValue {
        case "claude_code": "Claude Code"
        case "codex": "Codex CLI"
        case "gemini": "Gemini CLI"
        case "open_claw": "OpenClaw"
        case "open_code": "OpenCode"
        case "cline": "Cline"
        case "hermes": "Hermes Agent"
        case "code_buddy": "CodeBuddy"
        case "kimi_code": "Kimi Code"
        case "minimax_code": "MiniMax Code"
        case "grok": "Grok"
        case "cursor": "Cursor"
        case "deepseek": "DeepSeek Harness"
        case "qoder": "Qoder"
        case "antigravity": "Google Antigravity"
        case "kiro": "Kiro CLI"
        case "zcode": "ZCode"
        case "trae": "TRAE CLI"
        case "command_code": "Command Code"
        case "pi": "pi"
        default: rawValue
        }
    }
}

/// The app list an MCP editor saves (web `saveLocalServer`): the toggled
/// apps in display order, then every app the server already had that isn't
/// offered as a toggle — never added here, but never silently stripped
/// either, since the save would delete that app's on-disk entry.
enum McpAppSelection {
    static func apps(selected: Set<McpAppType>, existing: [McpAppType]) -> [McpAppType] {
        let visible = McpAppType.assignable.filter { selected.contains($0) }
        var seen = Set(visible)
        var hidden: [McpAppType] = []
        for app in existing where !McpAppType.assignable.contains(app) && seen.insert(app).inserted {
            hidden.append(app)
        }
        return visible + hidden
    }
}

/// What `mcp_scan_local` answers: every server the scan could read, plus a
/// warning per agent config it couldn't (Rust `LocalMcpScan`, codeg 0.30.2+).
/// Before that the route returned the bare server list, which still decodes.
struct LocalMcpScan: Decodable, Sendable {
    var servers: [LocalMcpServer]
    var warnings: [LocalMcpSourceWarning]

    private enum CodingKeys: String, CodingKey { case servers, warnings }

    init(servers: [LocalMcpServer], warnings: [LocalMcpSourceWarning] = []) {
        self.servers = servers
        self.warnings = warnings
    }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([LocalMcpServer].self) {
            servers = list
            warnings = []
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([LocalMcpServer].self, forKey: .servers) ?? []
        // A warning that doesn't decode drops alone, never the server list.
        let raw = (try? c.decodeIfPresent([FailableWarning].self, forKey: .warnings)) ?? nil
        warnings = (raw ?? []).compactMap(\.value)
    }

    private struct FailableWarning: Decodable {
        let value: LocalMcpSourceWarning?
        init(from decoder: Decoder) throws { value = try? LocalMcpSourceWarning(from: decoder) }
    }
}

/// One agent whose MCP config the scan couldn't read: its servers are missing
/// from the list (not removed), and the server refuses writes until it can
/// read every source.
struct LocalMcpSourceWarning: Decodable, Hashable, Sendable {
    let app: McpAppType
    let message: String
}

/// An installed local MCP server (`mcp_scan_local`). `spec` is the raw MCP server
/// definition (stdio/http/sse) kept as free-form JSON; `apps` keeps every
/// app string verbatim, known or not (see `McpAppType`).
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
        apps = rawApps.map(McpAppType.init(rawValue:))
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
