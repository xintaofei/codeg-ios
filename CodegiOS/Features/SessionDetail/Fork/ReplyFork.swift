import Foundation

// "Fork from here" (codeg 0.44, web `handleForkFromTurn` / `isForkPointUnnamed`
// / `markThreadTail`): fork the conversation at a settled reply. The backend
// does the whole reshuffle — the CURRENT row is cut back to the fork point and
// retitled `[Fork] …`, a new sibling row keeps the original, full history —
// so everything here is about naming the right point and reading the answer.

/// Where a reply's footer would fork: the reply's LAST assistant turn.
///
/// Forking is "up to and including this reply", and a reply the timeline
/// draws as one is often several persisted assistant turns merged
/// (`TranscriptTimeline.merge`, which keeps the FIRST turn's id for the row's
/// identity) — so the merged turn's id would fork in the middle of the reply.
/// The backend resolves the point against its own parse, by this id; it never
/// needs the agent's message id from us.
struct ReplyForkPoint: Equatable, Hashable, Sendable {
    /// The id of the reply's last assistant turn.
    let turnID: String
    /// Nothing renders after this reply (a failed round's closing line and
    /// text-less system turns aside): the one place where a tail fork — what
    /// the backend does with a point it cannot name — lands exactly where the
    /// user pointed.
    let isThreadTail: Bool
    /// The turn carries text of its own (see ``hasForkableText(_:)``) — what
    /// the backend resolves a fork point by, as far as this client can tell.
    var hasText: Bool = true
    /// The turn is one this client holds ahead of the server's own copy — an
    /// out-of-turn turn from the transcript watcher (``BackgroundOverlays``),
    /// whose id the backend's parse does not have.
    var heldAhead: Bool = false

    /// What a fork from this point sends.
    struct Request: Equatable, Sendable {
        /// nil forks at the tail.
        let forkFromTurnId: String?
    }

    /// The request to send for `agent`, or nil when this reply must not offer a
    /// fork — anywhere a tail fork would silently land somewhere other than the
    /// reply the user pointed at:
    ///
    /// - an id this client minted (`live-…` for a reply it streamed and folded
    ///   in, `pending-…` for its own prompt): the backend cannot resolve it;
    /// - an agent that cannot fork at a chosen message at all (everything but
    ///   Claude Code, Codex and DeepSeek — `resolve_fork_point`);
    /// - a turn with no text of its own (a reply that ended on a tool call):
    ///   Codex names a point only by its text's fingerprint, and Claude Code /
    ///   DeepSeek by that or the agent's message id — which this client never
    ///   sees, so it can't count on it.
    ///
    /// At the thread's tail all of them are fine — the tail IS the fork point —
    /// and the request then names nothing the backend would have to look up.
    func request(agent: AgentType) -> Request? {
        let local = heldAhead || Self.isLocalTurnID(turnID)
        let pointable = Self.canForkAtTurn(agent)
        if isThreadTail {
            return Request(forkFromTurnId: local || !pointable ? nil : turnID)
        }
        guard !local, pointable, hasText else { return nil }
        return Request(forkFromTurnId: turnID)
    }

    /// Whether `turn` has the text a fork point is fingerprinted from: its text
    /// blocks joined, not blank (backend `turn_text` + `text.trim().is_empty()`).
    static func hasForkableText(_ turn: MessageTurn) -> Bool {
        let text = turn.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined()
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Turn ids this client invents for its own optimistic state (see
    /// `LiveTurn`'s `live-…` and the send path's `pending-…`). The server's
    /// reconcile replaces them; until it does, they name nothing server-side.
    static func isLocalTurnID(_ id: String) -> Bool {
        id.hasPrefix("live-") || id.hasPrefix("pending-")
    }

    /// The agents whose `session/fork` honours a chosen message (backend
    /// `resolve_fork_point`); every other one forks at the tail whatever it is
    /// told.
    static func canForkAtTurn(_ agent: AgentType) -> Bool {
        switch agent {
        case .claudeCode, .codex: return true
        // DeepSeek has no case of its own in this build.
        default: return agent.rawValue == "deepseek"
        }
    }

    /// The index in `turns` of the assistant turn that ends the thread — where
    /// a tail fork lands — or nil when the thread does not end on a reply (a
    /// user message, or a system note, follows the newest one). Steps over what
    /// renders nothing and over a failed round's closing line: a tail fork keeps
    /// everything up to the reply before it, and the failure is nothing the
    /// agent carries on from (web `markThreadTail`).
    static func threadTailIndex(_ turns: [MessageTurn]) -> Int? {
        var index = turns.count - 1
        while index >= 0 {
            let turn = turns[index]
            switch turn.role {
            case .assistant:
                return index
            case .user:
                return nil
            case .system:
                // Drawn as a failure line, or not drawn at all: stepped over.
                if !turn.turnErrorText.isEmpty || SystemText.of(turn).isEmpty {
                    index -= 1
                    continue
                }
                return nil
            }
        }
        return nil
    }
}

/// Reading a fork's failure.
enum ForkFailure {
    /// The connection vanished between being found and being forked. The
    /// backend reports that as a 500 (`task_execution_failed`, "connection not
    /// found: <id>"), not a 404 — so the HTTP status alone does not say it.
    static func isConnectionGone(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if api.isStaleConnection { return true }
        if case .server(_, _, let message) = api {
            return message.lowercased().contains("connection not found")
        }
        return false
    }

    /// The agent has no `session/fork` (backend: "This agent does not support
    /// session/fork"). Fixed for the agent, so the affordance can go.
    static func isUnsupported(_ error: Error) -> Bool {
        guard let api = error as? APIError, case .server(_, _, let message) = api else { return false }
        return message.lowercased().contains("does not support session/fork")
    }

    /// The failure in words for a notice: the server's own message, without
    /// the `AcpError::Protocol` prefix that tells the user nothing.
    static func message(_ error: Error) -> String {
        if let api = error as? APIError, case .server(_, _, let message) = api, !message.isEmpty {
            return AcpErrorRoute.rejectedPromptText(message)
        }
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return error.localizedDescription
    }
}

/// Reading a snapshot's `fork_supported`.
enum ForkSupport {
    /// What a snapshot says about forking, or nil when it says nothing yet.
    ///
    /// The flag is `false` until the agent's `initialize` has run (the backend
    /// emits `fork_supported` just before it reports `connected`), so a
    /// snapshot taken while the connection is still coming up — or after it
    /// died — is not an answer.
    static func reading(status: ConnectionStatus?, supported: Bool?) -> Bool? {
        guard let supported, let status else { return nil }
        switch status {
        case .connected, .prompting: return supported
        case .connecting, .disconnected, .error: return nil
        }
    }
}

/// Whether a re-read after a fork shows the fork.
enum ForkRefetch {
    /// The row points at the forked session and its transcript is there. The
    /// agent writes the forked transcript itself, so the first read can come
    /// back before the file does — empty — and is then retried.
    static func isApplied(_ detail: ConversationDetail, forkedSessionId: String) -> Bool {
        detail.summary.externalId == forkedSessionId
            && (detail.turnsTotal ?? detail.turns.count) > 0
    }
}

/// What the last fork left behind, for the "open the original" banner.
struct ForkOutcome: Equatable, Identifiable, Sendable {
    let id = UUID()
    /// The new row that keeps the full, pre-fork history.
    let siblingConversationID: Int
}
