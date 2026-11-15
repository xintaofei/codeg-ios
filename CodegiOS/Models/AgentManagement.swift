import Foundation

/// Per-agent preflight diagnostics (`acp_preflight`). `status` is kept as a raw
/// string (lenient) so an unknown future check status can't fail the decode; the
/// UI colors known values (ok/pass = accent, warn = amber, error/fail = danger).
struct PreflightResult: Decodable, Sendable {
    let agentType: AgentType
    let agentName: String
    let passed: Bool
    let checks: [PreflightCheck]
    /// The adapter-vs-vendor-CLI facts, for an agent whose codeg entry is an
    /// ACP adapter (Claude Code → claude-agent-acp, Codex → codex-acp); nil
    /// for every other agent. Explains, never gates.
    let adapter: AdapterInfo?

    private enum CodingKeys: String, CodingKey { case agentType, agentName, passed, checks, adapter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentType = try c.decode(AgentType.self, forKey: .agentType)
        agentName = (try? c.decode(String.self, forKey: .agentName)) ?? ""
        passed = (try? c.decode(Bool.self, forKey: .passed)) ?? false
        checks = (try? c.decode([PreflightCheck].self, forKey: .checks)) ?? []
        adapter = (try? c.decodeIfPresent(AdapterInfo.self, forKey: .adapter)) ?? nil
    }
}

/// The adapter-vs-vendor-CLI split (Rust `AdapterInfo`). Neither `claude` nor
/// `codex` speaks ACP, so codeg installs and launches an adapter package
/// instead — and without saying so, "Not installed" beside an agent the user
/// demonstrably has reads as a bug. Facts, not prose: the client owns the
/// wording (and, on a phone that can install nothing, points at the desktop).
struct AdapterInfo: Decodable, Hashable, Sendable {
    /// npm spec codeg installs, e.g. `@agentclientprotocol/claude-agent-acp@0.81.1`.
    let adapterPackage: String
    /// The command the launch gate resolves, e.g. `claude-agent-acp`.
    let adapterCmd: String
    let adapterInstalled: Bool
    /// The vendor CLI, e.g. `claude`, and its display name.
    let nativeCmd: String
    let nativeLabel: String
    /// Where the user's own vendor CLI was found, if at all — named so the
    /// user can see codeg looked, and is talking about a different program.
    let nativePath: String?
    /// The adapter needs the official runtime installed separately (ZCode).
    let nativeRequired: Bool
    /// The config dir both read, so no second sign-in is needed.
    let sharedConfigDir: String
    let docsUrl: String

    private enum CodingKeys: String, CodingKey {
        case adapterPackage, adapterCmd, adapterInstalled, nativeCmd, nativeLabel, nativePath
        case nativeRequired, sharedConfigDir, docsUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ key: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        adapterPackage = str(.adapterPackage)
        adapterCmd = str(.adapterCmd)
        adapterInstalled = ((try? c.decodeIfPresent(Bool.self, forKey: .adapterInstalled)) ?? nil) ?? false
        nativeCmd = str(.nativeCmd)
        nativeLabel = str(.nativeLabel)
        let path = ((try? c.decodeIfPresent(String.self, forKey: .nativePath)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        nativePath = path?.isEmpty == false ? path : nil
        nativeRequired = ((try? c.decodeIfPresent(Bool.self, forKey: .nativeRequired)) ?? nil) ?? false
        sharedConfigDir = str(.sharedConfigDir)
        docsUrl = str(.docsUrl)
    }

    /// The note stands as fine (installed, and for a bridge, its runtime found).
    var isSettled: Bool { adapterInstalled && (!nativeRequired || nativePath != nil) }

    /// What the note says, in the one of five states the two facts put it
    /// (web `buildAcpAdapterCheck`, worded for a phone).
    var explanation: String {
        if nativeRequired {
            return String(localized: "Codeg runs \(adapterPackage) as an ACP bridge. Install and sign in to the official \(nativeLabel) on the desktop first; the bridge uses its existing configuration.")
        }
        switch (adapterInstalled, nativePath) {
        case (true, let path?):
            return String(localized: "Adapter \(adapterCmd) is installed — that is what Codeg launches, not your own \(nativeCmd) at \(path). They are separate packages that coexist, and both read \(sharedConfigDir), so sign-in and settings are shared.")
        case (true, nil):
            return String(localized: "Adapter \(adapterCmd) is installed — that is what Codeg launches. It ships its own runtime, so \(nativeLabel) is not required.")
        case (false, let path?):
            return String(localized: "Found your own \(nativeLabel) at \(path). Codeg drives agents over ACP and that CLI does not speak ACP, so it launches a separate adapter package, \(adapterPackage) — which isn't installed yet. The adapter never modifies or replaces your \(nativeCmd) command and reads the same \(sharedConfigDir), so your sign-in carries over. Install it from Agent Settings on the desktop.")
        case (false, nil):
            return String(localized: "Codeg drives agents over ACP and \(nativeLabel) does not speak ACP, so it launches a separate adapter package, \(adapterPackage). The adapter ships its own runtime, so the \(nativeCmd) CLI is not required first; if you do have it, the two coexist and share the same \(sharedConfigDir) sign-in. Install the adapter from Agent Settings on the desktop.")
        }
    }
}

struct PreflightCheck: Decodable, Hashable, Sendable, Identifiable {
    let checkId: String
    let label: String
    let status: String
    let message: String
    /// Server-suggested remediations (`fixes[]`). Optional/lenient so an older
    /// server that omits the field — or an unknown future fix kind — can't fail
    /// the decode. Rendered as tappable buttons under the check.
    let fixes: [FixAction]?

    var id: String { checkId }

    var isOK: Bool { ["ok", "pass", "passed", "success"].contains(status.lowercased()) }
    var isWarning: Bool { ["warn", "warning"].contains(status.lowercased()) }

    enum CodingKeys: String, CodingKey { case checkId, label, status, message, fixes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkId = (try? c.decode(String.self, forKey: .checkId)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        fixes = try? c.decodeIfPresent([FixAction].self, forKey: .fixes)
    }
}

/// The kinds of server-emitted preflight remediation. Closed set on the wire
/// (`FixActionKind`), but decoded leniently to `.unknown` so a new server kind
/// can't fail the list. Client-only install/upgrade/uninstall actions are a
/// separate concept — see ``AgentInstallAction``.
enum FixActionKind: String, Sendable, Hashable {
    case openURL = "open_url"
    case redownloadBinary = "redownload_binary"
    case retryConnection = "retry_connection"
    case openAgentsSettings = "open_agents_settings"
    case installOpenCodePlugins = "install_opencode_plugins"
    case installUv = "install_uv"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = FixActionKind(rawValue: raw) ?? .unknown
    }
}

extension FixActionKind: Decodable {}

/// One remediation button on a preflight check (`{label, kind, payload}`). Decode
/// is defensive (missing parts → empty / `.unknown`); a memberwise init is also
/// provided so the UI can synthesize fixes if ever needed.
struct FixAction: Decodable, Hashable, Sendable, Identifiable {
    let label: String
    let kind: FixActionKind
    let payload: String

    var id: String { "\(kind.rawValue)|\(payload)|\(label)" }

    enum CodingKeys: String, CodingKey { case label, kind, payload }

    init(label: String, kind: FixActionKind, payload: String) {
        self.label = label; self.kind = kind; self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        kind = (try? c.decode(FixActionKind.self, forKey: .kind)) ?? .unknown
        payload = (try? c.decode(String.self, forKey: .payload)) ?? ""
    }
}
