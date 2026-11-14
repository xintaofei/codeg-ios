import Foundation

/// What `acp_fork` reports (Rust `ForkResultInfo`). Serialized **camelCase**
/// by the backend (`#[serde(rename_all = "camelCase")]`), unlike nearly every
/// other response — `.convertFromSnakeCase` leaves keys without underscores
/// alone, so the shared decoder reads it as-is.
///
/// The server has already done the whole two-row reshuffle when this arrives:
/// the CURRENT conversation row points at the forked session (retitled
/// `[Fork] …`, title-locked), and `siblingConversationId` is a NEW row that
/// keeps the original, full history (status `pending_review`). The connection
/// id is unchanged — it now runs the fork.
struct ForkResult: Decodable, Equatable, Sendable {
    let forkedSessionId: String
    let originalSessionId: String
    let siblingConversationId: Int
}

/// Body for `acp_fork`. camelCase, encoded as-is. Every optional is sent as an
/// explicit `null` (the web does the same): `conversationId` + `folderId` link a
/// connection that has not prompted yet (both or neither), and a null
/// `forkFromTurnId` forks at the tail.
struct AcpForkBody: Encodable, Sendable {
    let connectionId: String
    let conversationId: Int?
    let folderId: Int?
    let forkFromTurnId: String?

    private enum CodingKeys: String, CodingKey {
        case connectionId, conversationId, folderId, forkFromTurnId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connectionId, forKey: .connectionId)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(folderId, forKey: .folderId)
        try c.encode(forkFromTurnId, forKey: .forkFromTurnId)
    }
}

extension CodegClient {
    /// Fork the conversation a live connection serves, at the assistant turn
    /// `forkFromTurnId` (nil = the tail).
    ///
    /// Long-timeout session: the backend queues the fork behind the agent's
    /// `initialize` — an idle conversation's connection may have just been
    /// spawned to resume it — and then waits on the agent's `session/fork`.
    ///
    /// Fails with ``APIError/turnInProgress`` (409) while a turn runs; anything
    /// else is a 500 `task_execution_failed` whose message says why — including
    /// a connection the server no longer has ("connection not found: …"), which
    /// is therefore NOT a 404 here.
    func forkConversation(
        connectionId: String,
        conversationId: Int?,
        folderId: Int?,
        forkFromTurnId: String?
    ) async throws -> ForkResult {
        try await postJSON(
            "acp_fork",
            AcpForkBody(
                connectionId: connectionId,
                conversationId: conversationId,
                folderId: folderId,
                forkFromTurnId: forkFromTurnId
            ),
            session: Self.probeSession
        )
    }
}
