import Foundation

/// One JetBrains AIR typed session failure (Rust `SessionFailureRecord`;
/// claude-agent-acp 0.67+ / codex-acp 1.2+, published because codeg advertises
/// `_meta.jetbrains.air`).
///
/// The wire carries UPSERTS ONLY — a record is revised in place through
/// `id` + `revision`, and adapters never publish resolution. `resolved` and
/// `dismissed` are this client's own inference (see ``SessionFailures``).
struct SessionFailureRecord: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let revision: Int
    /// `connection | access | limit | request | service | unknown` today.
    let category: String
    /// `"warning"` (transient, auto-recovering) or `"error"` (terminal).
    let severity: String
    /// Adapter-authored, already user-facing. May be empty — the category
    /// label stands in then.
    let title: String
    let details: String?
    /// Suggested recovery actions, a subset of `retry | login | new_session`.
    let actions: [String]
    var resolved: Bool
    /// Closed by the user (client-local): settled, but NOT recovered.
    var dismissed: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, revision, category, severity, title, details, actions, resolved
    }

    init(id: String, revision: Int, category: String, severity: String, title: String,
         details: String? = nil, actions: [String] = [], resolved: Bool = false, dismissed: Bool = false) {
        self.id = id
        self.revision = revision
        self.category = category
        self.severity = severity
        self.title = title
        self.details = details
        self.actions = actions
        self.resolved = resolved
        self.dismissed = dismissed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "unknown"
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "error"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details)
        actions = (try? c.decodeIfPresent([String].self, forKey: .actions)) ?? []
        resolved = (try? c.decodeIfPresent(Bool.self, forKey: .resolved)) ?? false
    }

    var isWarning: Bool { severity == "warning" }

    /// The localized category label — the title when the adapter sent a blank one.
    var categoryLabel: String {
        switch category {
        case "connection": return String(localized: "Connection issue")
        case "access": return String(localized: "Access issue")
        case "limit": return String(localized: "Limit reached")
        case "request": return String(localized: "Request rejected")
        case "service": return String(localized: "Service issue")
        default: return String(localized: "Session issue")
        }
    }

    /// What a strip calls it: the adapter's own first line, else the category.
    var displayTitle: String {
        SessionNotices.splitHeadline(title)?.title ?? categoryLabel
    }

    /// The adapter's own title, or nil when it sent a blank one.
    var ownTitle: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// The client half of the AIR session-failure contract — port of the web's
/// `src/lib/session-failures.ts` (codeg 0.44), which matches the backend's
/// `SessionState::apply_event` so a snapshot hydrate and a client that saw
/// every event agree.
///
/// - Monotonic per-id merge: accepted only when the revision is STRICTLY
///   higher (equal = a verbatim replay), and an accepted upsert re-arms
///   `resolved`. The one exception: an equal revision carrying
///   `resolved: true` hands a resolution to a client that missed the events
///   it was inferred from.
/// - Inferred resolution: retry incidents settle once the turn makes progress
///   again, warnings at a CLEAN turn end, everything when the user starts a
///   new prompt.
/// - Entries are kept after resolution as their id's revision watermark, so a
///   delayed stale upsert can never resurrect a settled record.
enum SessionFailures {
    enum SettleScope { case retryIncidents, warnings, all }

    enum NoticeKind: Equatable { case terminal, advisory }

    /// Merge upserts by the monotonic per-id rule.
    static func merge(_ current: [SessionFailureRecord], _ incoming: [SessionFailureRecord]) -> [SessionFailureRecord] {
        var next = current
        for record in incoming {
            guard !record.id.isEmpty, record.revision >= 1 else { continue }
            if let at = next.firstIndex(where: { $0.id == record.id }) {
                let stored = next[at]
                if record.revision < stored.revision { continue }
                if record.revision == stored.revision {
                    // Resolution moves false → true only; the stored copy keeps
                    // the client-local `dismissed` bit.
                    if record.resolved, !stored.resolved { next[at].resolved = true }
                    continue
                }
                var accepted = record
                accepted.dismissed = false
                next[at] = accepted
            } else {
                var accepted = record
                accepted.dismissed = false
                next.append(accepted)
            }
        }
        return next
    }

    /// A warning standing for an in-flight retry incident: the adapter lost the
    /// upstream and is reconnecting, so the next byte of output proves it
    /// recovered. Category "unknown" is where both adapters put their
    /// informational records, which nothing "recovers".
    static func isRetryIncident(_ f: SessionFailureRecord) -> Bool {
        f.isWarning && f.category != "unknown"
    }

    static func hasActiveRetryIncident(_ failures: [SessionFailureRecord]) -> Bool {
        failures.contains { !$0.resolved && isRetryIncident($0) }
    }

    static func latestActiveTerminalFailure(_ failures: [SessionFailureRecord]) -> SessionFailureRecord? {
        failures.last { !$0.resolved && !$0.isWarning }
    }

    /// Settle records at a lifecycle boundary; errors survive everything but `.all`.
    static func settle(_ failures: [SessionFailureRecord], _ scope: SettleScope) -> [SessionFailureRecord] {
        failures.map { f in
            guard !f.resolved else { return f }
            let settles: Bool
            switch scope {
            case .all: settles = true
            case .warnings: settles = f.isWarning
            case .retryIncidents: settles = isRetryIncident(f)
            }
            var out = f
            if settles { out.resolved = true }
            return out
        }
    }

    /// The user closed a strip. Marked distinctly from recovery, and applied to
    /// already-resolved records too (the "recovered" line is one).
    static func dismiss(_ failures: [SessionFailureRecord], ids: [String]) -> [SessionFailureRecord] {
        let targets = Set(ids)
        return failures.map { f in
            guard targets.contains(f.id) else { return f }
            var out = f
            out.resolved = true
            out.dismissed = true
            return out
        }
    }

    struct RetryIncidentView: Equatable {
        var incident: SessionFailureRecord?
        var hiddenCount: Int
        /// Every active incident the one strip stands for — what closing it closes.
        var ids: [String]
    }

    /// Active retry incidents collapse to ONE strip (the last in table order)
    /// plus a count — a turn that reconnects N times must not stack N strips.
    static func activeRetryIncidentView(_ failures: [SessionFailureRecord]) -> RetryIncidentView {
        let incidents = failures.filter { !$0.resolved && isRetryIncident($0) }
        return RetryIncidentView(incident: incidents.last,
                                 hiddenCount: max(0, incidents.count - 1),
                                 ids: incidents.map(\.id))
    }

    /// Whether an incoming upsert is news to tell the user, and as what. Nil
    /// for a stale/replayed revision, a retry incident (drawn live instead), or
    /// a re-publish of what is already showing.
    static func notice(stored: SessionFailureRecord?, incoming: SessionFailureRecord) -> NoticeKind? {
        guard !incoming.id.isEmpty, incoming.revision >= 1 else { return nil }
        if let stored, incoming.revision <= stored.revision { return nil }
        if isRetryIncident(incoming) { return nil }
        if let stored, !stored.resolved,
           stored.severity == incoming.severity,
           stored.title == incoming.title,
           (stored.details ?? "") == (incoming.details ?? ""),
           stored.actions == incoming.actions {
            return nil
        }
        return incoming.isWarning ? .advisory : .terminal
    }

    /// The most recent retry incident that settled ON ITS OWN — never one the
    /// user dismissed (closing a strip must remove it, not claim a recovery).
    static func mostRecentRecoveredWarning(_ failures: [SessionFailureRecord]) -> SessionFailureRecord? {
        failures.last { $0.resolved && !$0.dismissed && isRetryIncident($0) }
    }

    /// What the dock under the transcript shows.
    struct DockView: Equatable {
        var incident: RetryIncidentView?
        var recovered: SessionFailureRecord?
        var isEmpty: Bool { incident == nil && recovered == nil }
    }

    /// Web `SessionFailureBanner` + `ComposerStatusStrips`: incidents only while
    /// a turn runs and no richer retry line shows the same retry; the
    /// "recovered" line only once nothing is still failing.
    static func dock(_ failures: [SessionFailureRecord], turnRunning: Bool, retryLineShown: Bool) -> DockView {
        let view = activeRetryIncidentView(failures)
        let recovered = (view.incident != nil || latestActiveTerminalFailure(failures) != nil)
            ? nil : mostRecentRecoveredWarning(failures)
        let shown = (retryLineShown || !turnRunning || view.incident == nil) ? nil : view
        return DockView(incident: shown, recovered: recovered)
    }
}

/// A retry the agent is making on its own (web `ClaudeApiRetryState`): Claude's
/// `api_retry` SDK message, or `turn_retrying` (codex's `_meta.codex.error`,
/// pi's auto-retry announcement).
struct TurnRetryState: Hashable, Sendable {
    var attempt: Int?
    var maxRetries: Int?
    var error: String?
    var errorStatus: Int?
    var retryDelayMs: Double?
    /// Whether the SOURCE reports a cause at all. Claude and codex do (a
    /// missing one gets the fallback wording); pi never does, so its line is
    /// built from the counters alone rather than inventing a reason.
    var reportsError: Bool

    /// Claude's `system/api_retry` SDK message, or nil for any other one (which
    /// the web reads as "no retry in flight" and clears the line with).
    static func fromClaudeSdkMessage(_ message: AnyJSON?) -> TurnRetryState? {
        guard let o = message?.object,
              o["type"]?.string == "system", o["subtype"]?.string == "api_retry" else { return nil }
        // The shared decoder converts nested keys too, so probe both spellings.
        func field(_ snake: String, _ camel: String) -> AnyJSON? { o[snake] ?? o[camel] }
        return TurnRetryState(
            attempt: finiteInt(o["attempt"]),
            maxRetries: finiteInt(field("max_retries", "maxRetries")),
            error: o["error"]?.string,
            errorStatus: finiteInt(field("error_status", "errorStatus")),
            retryDelayMs: finiteDouble(field("retry_delay_ms", "retryDelayMs")),
            reportsError: true)
    }

    /// The web's `asFiniteNumber`: a number, or a numeric string.
    private static func finiteDouble(_ v: AnyJSON?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n : nil
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let n = Double(t), n.isFinite else { return nil }
            return n
        default: return nil
        }
    }

    private static func finiteInt(_ v: AnyJSON?) -> Int? {
        finiteDouble(v).map { Int($0.rounded(.towardZero)) }
    }

    /// The one-line text of the retry line (web `useRetryLineText`), e.g.
    /// "overloaded_error (HTTP 529) · retrying 2/10, next in 4.0s".
    var lineText: String {
        let retry: String
        if let attempt, let maxRetries {
            retry = String(localized: "retrying \(attempt)/\(maxRetries)")
        } else if let attempt {
            retry = String(localized: "retrying attempt \(attempt)")
        } else {
            retry = String(localized: "retrying")
        }
        let delay = retryDelayMs.map { ms -> String in
            let seconds = String(format: "%.1f", ms / 1000)
            return String(localized: "next in \(seconds)s")
        }
        let errorLabel = error ?? (reportsError ? "authentication_failed" : nil)
        let status = errorStatus.map { String(localized: " (HTTP \($0))") } ?? ""
        if errorLabel == nil, status.isEmpty {
            // Nothing before the separator — the counters carry the message.
            if let delay { return String(localized: "\(retry), \(delay)") }
            return retry
        }
        let cause = (errorLabel ?? "") + status
        if let delay { return String(localized: "\(cause) · \(retry), \(delay)") }
        return "\(cause) · \(retry)"
    }
}

/// One ACP Session Notice (Rust `SessionNotice`) — fire-and-forget advisory
/// text with no id and no lifecycle.
struct SessionNoticeInfo: Decodable, Hashable, Sendable {
    let severity: String
    let title: String
    let description: String?

    init(severity: String, title: String, description: String? = nil) {
        self.severity = severity
        self.title = title
        self.description = description
    }
}

/// One plugin Claude Code could not load (Rust `PluginLoadFailure`).
struct PluginLoadFailure: Decodable, Hashable, Sendable {
    let plugin: String
    let kind: String
    let message: String
    let path: String?
}

/// How notices, advisories and plugin failures are told — ports of the web's
/// `session-notices.ts` and `plugin-load-failures.ts`. iOS tells them on the
/// composer's notice line rather than as toasts.
enum SessionNotices {
    /// Split adapter text into its first non-empty line and the rest (followed
    /// by `more`). Nil when there is no text at all.
    static func splitHeadline(_ text: String, more: String? = nil) -> (title: String, description: String?)? {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let title = lines[first].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [rest, more?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""].filter { !$0.isEmpty }
        return (title, parts.isEmpty ? nil : parts.joined(separator: "\n"))
    }

    /// A notice that only restates a compaction, which the transcript's own
    /// compaction row already shows.
    static func isCompactionEcho(_ notice: SessionNoticeInfo) -> Bool {
        let text = "\(notice.title)\n\(notice.description ?? "")"
        if text.range(of: #"\bmultiple compactions\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return notice.severity == "info"
            && notice.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "context compacted"
    }

    /// The notice line for a session notice, or nil when it should not show.
    static func present(_ notice: SessionNoticeInfo) -> String? {
        if isCompactionEcho(notice) { return nil }
        guard let headline = splitHeadline(notice.title, more: notice.description) else { return nil }
        return joined(headline)
    }

    /// The notice line for a failure record told as news (an advisory, or a
    /// failed turn): its title's headline, then the rest and the details.
    static func present(_ record: SessionFailureRecord) -> String {
        let categoryLabel = record.categoryLabel
        if let headline = splitHeadline(record.title, more: record.details) { return joined(headline) }
        let details = record.details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return details.isEmpty ? categoryLabel : "\(categoryLabel)\n\(details)"
    }

    /// The notice line for plugins Claude Code could not load: a count, then
    /// one line per entry in the CLI's own words.
    static func present(_ failures: [PluginLoadFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        let labels = Set(failures.map(label))
        let lines = failures.map { f -> String in
            let message = f.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "\(label(f)) (\(f.kind))" : "\(label(f)): \(message)"
        }
        let title = String(localized: "\(labels.count) plugins couldn’t load")
        return ([title] + lines).joined(separator: "\n")
    }

    /// A positional `inline[N]` / `synced[N]` tag reads better as its path.
    static func label(_ failure: PluginLoadFailure) -> String {
        let path = failure.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let positional = failure.plugin.range(of: #"^(?:inline|synced)\[\d+\]$"#, options: .regularExpression) != nil
        return positional && !path.isEmpty ? path : failure.plugin
    }

    private static func joined(_ headline: (title: String, description: String?)) -> String {
        headline.description.map { "\(headline.title)\n\($0)" } ?? headline.title
    }

    /// The message for a `session_load_failed` (web `ACP_LOAD_ERROR`),
    /// localized by its stable code; the agent's own text for an unknown one.
    static func sessionLoadFailure(code: String, message: String, sessionId: String, agent: String, agentIsCodex: Bool) -> String {
        switch code {
        case "resource_not_found":
            return String(localized: "\(agent) session failed to load. Reload to retry, or start a new conversation.")
        case "session_unavailable":
            return String(localized: "\(agent) couldn’t restore this session — it may have ended or the agent stopped. Reload to retry, or start a new conversation.")
        case "session_busy":
            return String(localized: "This session is open elsewhere. If another \(agent) client (the app, the CLI or an IDE extension) has it, close it there or quit that client, then reload. If you just forked it, reload in about a minute.")
        case "provider_mismatch":
            return String(localized: "This conversation was started with a different model provider than the one \(agent) uses now, and \(agent) only continues a conversation on its own provider. Switch back to that provider in \(agent)’s settings and reload, or start a new conversation. (\(message))")
        case "session_archived":
            guard let command = recoveryCommand(code: code, sessionId: sessionId, agentIsCodex: agentIsCodex) else {
                return message
            }
            return String(localized: "The previous session was archived on the \(agent) side. Run \(command) in a terminal to restore it and reload, or start a new conversation.")
        default:
            return message
        }
    }
}
