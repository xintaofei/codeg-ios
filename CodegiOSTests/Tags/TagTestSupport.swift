import Foundation
@testable import Codeg

/// Builders shared by the tag suites. Summaries go through the real decoder,
/// so every test also reads the wire shape (`tag_ids` absent when empty).
enum TagFixtures {
    static func summary(
        _ id: Int,
        folder: Int = 1,
        tags: [Int] = [],
        branch: String? = nil,
        parent: Int? = nil,
        kind: String? = nil,
        pinned: Bool = false,
        updated: String = "2024-01-02T03:04:05Z",
        status: String = "completed"
    ) -> ConversationSummary {
        var json: [String: Any] = [
            "id": id, "folder_id": folder, "agent_type": "codex", "status": status,
            "message_count": 0, "created_at": "2024-01-02T03:04:05Z", "updated_at": updated,
        ]
        if !tags.isEmpty { json["tag_ids"] = tags }
        if let branch { json["git_branch"] = branch }
        if let parent { json["parent_id"] = parent }
        if let kind { json["kind"] = kind }
        if pinned { json["pinned_at"] = "2024-01-03T00:00:00Z" }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! CodegJSON.decoder.decode(ConversationSummary.self, from: data)
    }

    static func folder(_ id: Int, parent: Int? = nil, kind: FolderKind = .regular, name: String? = nil,
                       sortOrder: Int = 0, path: String? = nil, branch: String? = nil) -> FolderDetail {
        FolderDetail(id: id, name: name ?? "f\(id)", path: path ?? "/f\(id)", gitBranch: branch,
                     defaultAgentType: nil, lastOpenedAt: Date(timeIntervalSince1970: 0),
                     sortOrder: sortOrder, color: "", parentId: parent, kind: kind)
    }

    static func tag(_ id: Int, folder: Int? = nil, order: Int = 0, name: String? = nil,
                    color: String = "#cf222e") -> ConversationTag {
        ConversationTag(id: id, folderId: folder, name: name ?? "t\(id)", color: color, sortOrder: order)
    }
}

/// Opens when told to; everything waiting on it resumes then.
@MainActor
final class TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }
}

/// A server whose tag writes are answered by hand, in the order a test
/// chooses — the write ordering is what the picker suites are about.
@MainActor
final class FakeTagServer: ConversationTagsAPI {
    struct Write: Equatable {
        let conversation: Int
        let add: [Int]
        let remove: [Int]
    }

    var tags: [ConversationTag] = [TagFixtures.tag(1, name: "one")]
    /// Holds `listConversationTags` until opened.
    var listGate: TestGate?
    /// Holds `createConversationTag` until opened.
    var createGate: TestGate?
    var nextTagID = 9
    private(set) var writes: [Write] = []
    private(set) var listCalls = 0
    /// What the server holds, per conversation, as the answered writes left it.
    private(set) var held: [Int: Set<Int>] = [:]
    private var pending: [CheckedContinuation<ConversationSummary, Error>] = []
    private var answered = 0

    var outstanding: Int { pending.count }

    func listConversationTags() async throws -> [ConversationTag] {
        listCalls += 1
        await listGate?.wait()
        return tags
    }

    func listFolders() async throws -> [FolderDetail] {
        [TagFixtures.folder(1)]
    }

    func createConversationTag(folderId: Int?, name: String, color: String) async throws -> ConversationTag {
        await createGate?.wait()
        let tag = ConversationTag(id: nextTagID, folderId: folderId, name: name, color: color)
        nextTagID += 1
        tags.append(tag)
        return tag
    }

    func updateConversationTags(conversationId: Int, add: [Int], remove: [Int]) async throws -> ConversationSummary {
        writes.append(Write(conversation: conversationId, add: add, remove: remove))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    /// Answer the oldest write as the server would (removals first).
    func answer() {
        let write = writes[answered]
        answered += 1
        var set = held[write.conversation] ?? []
        set.subtract(write.remove)
        set.formUnion(write.add)
        held[write.conversation] = set
        pending.removeFirst().resume(returning: TagFixtures.summary(write.conversation, tags: set.sorted()))
    }

    /// Refuse the oldest write.
    func refuse() {
        answered += 1
        pending.removeFirst().resume(throwing: APIError.server(status: 400, code: "invalid_input", message: "refused"))
    }
}

/// Polls `condition` on the main actor until it holds (or two seconds pass):
/// the picker's work hops through child tasks, so a fixed number of yields
/// would be a guess.
@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// Gives queued work a moment, for checks that something did NOT happen.
@MainActor
func letQueuedWorkRun() async {
    try? await Task.sleep(for: .milliseconds(40))
}
