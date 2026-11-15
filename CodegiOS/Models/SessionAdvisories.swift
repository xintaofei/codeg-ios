import Foundation

/// What a settings save changed under a running agent (Rust `ConfigStaleKind`).
enum ConfigStaleKind: Hashable, Sendable {
    /// Agent env vars, enabled flag, model-provider binding or native config file.
    case agentConfig
    /// A model provider row the agent is bound to (url / key / model).
    case modelProvider

    /// Nil for a kind this build doesn't know — still stale, just unnamed.
    init?(wire: String?) {
        switch wire {
        case "agent_config": self = .agentConfig
        case "model_provider": self = .modelProvider
        default: return nil
        }
    }
}

/// The running agent is still on its launch-time settings after a later save
/// (web `configStale` + `configStaleDismissed`). Dismissing hides the banner for
/// THIS drift only: a fresh `session_config_stale` brings it back.
struct ConfigStale: Hashable, Sendable {
    var kind: ConfigStaleKind?
    var dismissed = false
}

/// Claude Code's Remote Control while it is on (Rust `RemoteControlInfo`): the
/// session can be continued from claude.ai/code or the Claude app for as long
/// as the agent CLI runs.
struct RemoteControlInfo: Hashable, Sendable, Decodable {
    /// The remote session's link; nil when Claude Code turned Remote Control on
    /// without returning one.
    let sessionUrl: String?

    init(sessionUrl: String?) {
        let trimmed = sessionUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.sessionUrl = trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey { case sessionUrl }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionUrl: (try? c.decodeIfPresent(String.self, forKey: .sessionUrl)) ?? nil)
    }

    /// The link as something to open: web links only. Anything else is still
    /// shown and copied, never opened.
    var openableURL: URL? {
        guard let sessionUrl, let url = URL(string: sessionUrl),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// The agent settled a config-option pick somewhere other than where the user
/// put it (Rust `AcpEvent::ConfigOptionRejected`): pi for a model whose
/// reasoning it can't honour, grok for a model switch mid-conversation. The
/// labels are the option's own; the raw ids ride beside them.
struct ConfigOptionRejection: Hashable, Sendable {
    let configId: String
    let optionName: String
    let requested: String
    let actual: String
}

/// A `session/load` that failed for good, as the banner in the composer's place
/// tells it (web `loadError` + `loadErrorCommand`).
struct SessionLoadFailure: Hashable, Sendable {
    let message: String
    /// The exact shell line that undoes it, when there is one (`codex unarchive <id>`).
    let command: String?
}

// MARK: - Decoding

/// Decoding for the connection's advisories and the two facts about its process
/// that every snapshot restates. Reached from the main `AcpEvent` decoder after
/// ``decodeRunsEvent(type:from:)``; lenient like it — a frame of the wrong shape
/// comes back nil, and so `.unknown`, rather than dropping the envelope.
extension AcpEvent {
    private enum AdvisoryKeys: String, CodingKey {
        case configId, optionName, requested, actual, stale, kind, remoteControl
    }

    static func decodeAdvisoryEvent(type: String, from decoder: Decoder) -> AcpEvent? {
        guard let c = try? decoder.container(keyedBy: AdvisoryKeys.self) else { return nil }
        func string(_ key: AdvisoryKeys) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? ""
        }
        switch type {
        case "config_option_rejected":
            let rejection = ConfigOptionRejection(
                configId: string(.configId), optionName: string(.optionName),
                requested: string(.requested), actual: string(.actual))
            guard !rejection.configId.isEmpty else { return nil }
            return .configOptionRejected(rejection)
        case "session_config_stale":
            guard let stale = (try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? nil else { return nil }
            return .sessionConfigStale(stale: stale, kind: ConfigStaleKind(wire: string(.kind)))
        case "remote_control":
            // `null` (or absent) is Remote Control turning off.
            return .remoteControl((try? c.decodeIfPresent(RemoteControlInfo.self, forKey: .remoteControl)) ?? nil)
        default:
            return nil
        }
    }
}

// MARK: - Presentation

extension SessionNotices {
    /// The notice for a pick the agent settled elsewhere (web
    /// `configOptionAdjusted`). Reporting only: the saved preference keeps what
    /// was asked for, since a refusal is often about this session rather than
    /// the pick (grok's switch works in a new one).
    static func configOptionAdjusted(_ rejection: ConfigOptionRejection, agent: String) -> String {
        let option = rejection.optionName.isEmpty ? rejection.configId : rejection.optionName
        return String(localized: "\(agent) set \(option) to \(rejection.actual) instead of \(rejection.requested)")
    }

    /// The one command that undoes `codex archive`, or nil. Only for codex —
    /// telling another agent's user to run it would be worse than nothing — and
    /// only for an id shaped like a codex rollout id: this is a line the user is
    /// invited to paste into a shell, so it must not be able to carry anything
    /// but a session id.
    static func recoveryCommand(code: String, sessionId: String, agentIsCodex: Bool) -> String? {
        guard code == "session_archived", agentIsCodex,
              sessionId.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                              options: .regularExpression) != nil
        else { return nil }
        return "codex unarchive \(sessionId)"
    }

    /// Background tasks a `<task-notification>` settled, told once per batch
    /// (web raises an OS notification per entry). Nil when every one is
    /// interim — those tasks will report again.
    static func backgroundSettled(_ settled: [BackgroundSettled], agent: String) -> String? {
        let finished = settled.filter { !$0.interim }
        guard let first = finished.first else { return nil }
        if finished.count > 1 {
            return String(localized: "\(agent): \(finished.count) background tasks finished")
        }
        let summary = first.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let what = summary.isEmpty ? String(localized: "Background task finished (\(first.status))") : summary
        return String(localized: "\(agent): \(what)")
    }

    /// A resumed connection that was gone before its stream could attach,
    /// twice: the server ends a connection whose `session/load` failed for
    /// good, and says why only on that connection's own stream, which nothing
    /// was listening to yet.
    static func sessionLoadUnconfirmed(agent: String) -> String {
        String(localized: "\(agent) couldn’t open this session — it may have ended, been archived, or be open elsewhere. Reload to retry, or start a new conversation.")
    }
}
