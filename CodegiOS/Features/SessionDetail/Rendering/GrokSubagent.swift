import Foundation

/// Grok's sub-agent signals, read off a launching Agent tool call.
///
/// Grok runs every `spawn_subagent` child as a FULL, standalone session — its
/// own directory, its own transcript — and forwards none of the child's chunks
/// or tool calls over ACP. So unlike Claude's `Task` (whose sub-agent output
/// streams into the parent call), a grok Agent card has nothing of the child to
/// show. These two signals are what exist instead: a periodic progress tick, and
/// the child's session id.
///
/// Ports the web's `parseGrokSubagentProgress` / `parseChildSessionId`.
enum GrokSubagent {

    // MARK: Progress ticker

    /// A `subagent_progress` tick. Every field is independently optional: grok
    /// sends whichever counters it has, and the backend forwards only the numeric
    /// ones (`connection.rs::map_grok_subagent_notification`).
    struct Progress: Equatable {
        var durationMs: Double?
        var turnCount: Int?
        var toolCallCount: Int?
        var contextUsagePct: Double?
    }

    /// The live ticker on the launching call's `meta.grokSubagentProgress`.
    /// `nil` for every other meta shape, and for a tick that carried no numbers
    /// at all — there is nothing to say, and an empty line is worse than none.
    static func progress(meta: AnyJSON?) -> Progress? {
        guard let raw = meta?["grokSubagentProgress"], raw.object != nil else { return nil }
        let p = Progress(
            durationMs: raw["durationMs"]?.double,
            turnCount: raw["turnCount"]?.double.map { Int($0) },
            toolCallCount: raw["toolCallCount"]?.double.map { Int($0) },
            contextUsagePct: raw["contextUsagePct"]?.double
        )
        let empty = p.durationMs == nil && p.turnCount == nil
            && p.toolCallCount == nil && p.contextUsagePct == nil
        return empty ? nil : p
    }

    // MARK: Child session

    /// The child's own session, when the sub-agent ran as one.
    ///
    /// Live it arrives as `meta.grokSubagentSession.childSessionId`, re-sent on
    /// every progress tick because the backend replaces the block's meta
    /// wholesale; in history it comes off the parsed
    /// `agent_stats.child_session_id`. Available live as well as after the fact,
    /// so a blocking child can be watched *while* it works rather than only once
    /// it reports back.
    ///
    /// The agent type is pinned to grok because those two fields have no other
    /// producer, and a grok parent's child is itself a grok session — the card
    /// has no conversation-level agent type of its own to read here.
    static func childSession(meta: AnyJSON?, stats: AgentExecutionStats?) -> ChildSession? {
        if let live = meta?["grokSubagentSession"]?["childSessionId"]?.nonEmptyString {
            return ChildSession(sessionId: live, agentType: .grok)
        }
        guard let persisted = stats?.childSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !persisted.isEmpty
        else { return nil }
        return ChildSession(sessionId: persisted, agentType: .grok)
    }

    struct ChildSession: Equatable {
        let sessionId: String
        let agentType: AgentType
    }

    // MARK: Background launch

    /// Whether this call's output is a BACKGROUND launch acknowledgement rather
    /// than a child's result — Claude's ("Async agent launched successfully. …")
    /// or grok's `spawn_subagent(background: true)` ("Subagent started in
    /// background.\nsubagent_id: …").
    ///
    /// It matters because such a launcher settles the moment it is acknowledged
    /// while the child keeps working (`parsers/grok.rs`'s background fixture, and
    /// `connection.rs`'s "a spawn whose CALL already settled = a BACKGROUND
    /// child"). Reading the launcher's own state would therefore call a child
    /// finished the instant it started. Ports the web's `isAsyncLaunchAckText`.
    static func isBackgroundLaunchAck(_ output: String?) -> Bool {
        guard let output else { return false }
        return output.contains("Async agent launched successfully")
            || output.drop(while: \.isWhitespace).hasPrefix("Subagent started in background")
    }
}
