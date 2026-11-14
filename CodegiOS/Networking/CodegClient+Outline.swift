import Foundation

/// The message navigator's view of the history ABOVE a loaded window
/// (`get_folder_conversation_outline`, codeg 0.36+): `full[0..<min(beforeIndex,
/// total))`, ONE entry per turn — so `turns[i]` is global turn `i` — each
/// trimmed to what the navigator reads:
///
/// - a user turn keeps only its first non-empty text block (the label);
/// - an assistant turn keeps every `tool_use`, and of the results only a
///   call's first successful one that carries a hunk-numbered diff;
/// - a system turn keeps no blocks.
///
/// Not paged: one response covers the whole prefix. `prefixHash` fingerprints
/// `full[0..<turns.count)` — equal to the window's own `prefix_hash` when the
/// outline was cut at the window's start, which is how it is checked before
/// use (see ``OutlineValidity``).
struct ConversationOutline: Decodable, Sendable {
    let turns: [MessageTurn]
    let turnsTotal: Int
    let prefixHash: String
}

/// Body for `get_folder_conversation_outline`. camelCase, as every request.
struct ConversationOutlineBody: Encodable, Sendable {
    let conversationId: Int
    let beforeIndex: Int
}

extension CodegClient {
    /// The outline of the history above `beforeIndex` (the loaded window's
    /// offset). A server without the route (≤ 0.35) is recognised before ever
    /// asking: its details carry no `user_turns_before_offset`.
    ///
    /// The default session: the server parses the whole transcript for this,
    /// so a long session takes longer than the snappy read session allows.
    func conversationOutline(id: Int, beforeIndex: Int) async throws -> ConversationOutline {
        try await postJSON("get_folder_conversation_outline", ConversationOutlineBody(
            conversationId: id, beforeIndex: beforeIndex
        ))
    }
}
