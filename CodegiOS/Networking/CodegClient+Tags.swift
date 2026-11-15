import Foundation

// MARK: - Request bodies (camelCase; a nil optional is left out)

/// Body for `create_conversation_tag`. `folderId` omitted = a global tag; a
/// worktree's folder resolves to its repo's scope server-side.
struct CreateConversationTagBody: Encodable, Sendable {
    let folderId: Int?
    let name: String
    let color: String
}

/// Body for `update_conversation_tag`. A field left out is left as it is.
struct UpdateConversationTagBody: Encodable, Sendable {
    let tagId: Int
    let name: String?
    let color: String?
}

/// Body for `delete_conversation_tag`.
struct ConversationTagIdBody: Encodable, Sendable {
    let tagId: Int
}

/// Body for `reorder_conversation_tags`: one scope's complete order.
struct ReorderConversationTagsBody: Encodable, Sendable {
    let tagIds: [Int]
}

/// Body for `update_conversation_tags`: a delta. Removals apply first, so an
/// id in both ends up on.
struct UpdateConversationTagsBody: Encodable, Sendable {
    let conversationId: Int
    let add: [Int]
    let remove: [Int]
}

/// Body for `update_conversation_branch_tag`: the whole setting.
struct UpdateBranchTagBody: Encodable, Sendable {
    let enabled: Bool
    let color: String
}

/// The server calls the tag picker makes — `CodegClient` in the app, a server
/// answered by hand in tests (the write ordering is the point of those).
protocol ConversationTagsAPI: Sendable {
    func listConversationTags() async throws -> [ConversationTag]
    func listFolders() async throws -> [FolderDetail]
    func createConversationTag(folderId: Int?, name: String, color: String) async throws -> ConversationTag
    func updateConversationTags(conversationId: Int, add: [Int], remove: [Int]) async throws -> ConversationSummary
}

/// Conversation tags (codeg 0.44, `web/handlers/conversation_tags.rs`). Every
/// route is `POST /api/<name>`; bodies are camelCase, responses snake_case.
extension CodegClient: ConversationTagsAPI {
    /// Who a tag write belongs to: the server, whichever token reaches it — so
    /// a token edited mid-write still has one writer per conversation.
    var tagEndpoint: String { baseURL.absoluteString }

    /// Every tag: global ones first, then by folder, each scope in its order.
    func listConversationTags() async throws -> [ConversationTag] {
        try await postJSON("list_conversation_tags", EmptyBody(), session: Self.readSession)
    }

    /// A new tag at the end of its scope (nil `folderId` = global). The server
    /// trims the name and caps it at 64 characters; a name already used in the
    /// scope (case-insensitively) is refused with `already_exists`.
    func createConversationTag(folderId: Int?, name: String, color: String) async throws -> ConversationTag {
        try await postJSON("create_conversation_tag",
                           CreateConversationTagBody(folderId: folderId, name: name, color: color))
    }

    /// Rename and/or recolour a tag; a nil field is left alone.
    func updateConversationTag(tagId: Int, name: String?, color: String?) async throws -> ConversationTag {
        try await postJSON("update_conversation_tag",
                           UpdateConversationTagBody(tagId: tagId, name: name, color: color))
    }

    /// Delete a tag, taking it off every conversation that has it. Response is `null`.
    func deleteConversationTag(tagId: Int) async throws {
        _ = try await send("delete_conversation_tag", body: ConversationTagIdBody(tagId: tagId))
    }

    /// Persist one scope's order: each id takes its position in `tagIds`.
    /// Response is `null`.
    func reorderConversationTags(tagIds: [Int]) async throws {
        _ = try await send("reorder_conversation_tags", body: ReorderConversationTagsBody(tagIds: tagIds))
    }

    /// Put tags on / take them off a conversation; answers with its summary as
    /// it now stands (the same row every other client is sent).
    func updateConversationTags(conversationId: Int, add: [Int], remove: [Int]) async throws -> ConversationSummary {
        try await postJSON("update_conversation_tags",
                           UpdateConversationTagsBody(conversationId: conversationId, add: add, remove: remove))
    }

    func conversationBranchTag() async throws -> BranchTagSetting {
        try await postJSON("get_conversation_branch_tag", EmptyBody(), session: Self.readSession)
    }

    /// Save the whole branch tag setting; answers with it as saved.
    func updateConversationBranchTag(enabled: Bool, color: String) async throws -> BranchTagSetting {
        try await postJSON("update_conversation_branch_tag", UpdateBranchTagBody(enabled: enabled, color: color))
    }
}
