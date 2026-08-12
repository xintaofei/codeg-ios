import Foundation

/// A session read straight off the agent's own transcript files, by its NATIVE
/// session id — not a codeg conversation row.
///
/// `get_conversation` parses any session the agent wrote, whether or not codeg
/// tracked it: sub-agent sessions are hidden from every listing, but a direct
/// open still resolves. That is what makes a grok `spawn_subagent` child
/// readable at all, and — because the child streams its transcript to disk as it
/// works — re-reading it on a timer is a real live view of a running child.
///
/// Deliberately a separate type from `ConversationDetail`: that one mirrors the
/// DB row (`Int` id, folder, status, pinning, a turn window), none of which a
/// native session has. Only `turns` and `sessionStats` are shared.
struct AgentSessionDetail: Decodable, Sendable {
    let summary: AgentSessionSummary
    let turns: [MessageTurn]
    let sessionStats: SessionStats?
}

/// Identity of a native session (Rust `ConversationSummary` — the ACP-side one,
/// not `DbConversationSummary`). Only the fields the sub-agent viewer shows are
/// decoded.
struct AgentSessionSummary: Decodable, Sendable {
    /// The native session id (a uuid-ish string), not a codeg row id.
    let id: String
    let agentType: AgentType
    let title: String?
    let model: String?
    let messageCount: Int
    let startedAt: Date
    let endedAt: Date?
}
