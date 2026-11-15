import Foundation
import Observation

/// One server's tag definitions and branch tag setting, for a surface that
/// draws conversations' chips without holding the Chats list's copy: the
/// session screen's header, the Activity tab, Search. Read when the surface
/// appears and again whenever a tag is created, renamed, recoloured,
/// reordered or deleted (``Notification/Name/conversationTagDefinitionsDidChange``).
/// The tags each conversation carries come with its summary, not from here.
///
/// A server without tags — or a read that failed — only goes without chips.
@MainActor
@Observable
final class TagDefinitionsModel {
    private(set) var tagsByID: [Int: ConversationTag] = [:]
    private(set) var branchTag = BranchTagSetting()

    /// The server the definitions are from (``CodegClient/tagEndpoint``): ids
    /// are a server's own, so another server's never resolve here.
    @ObservationIgnored private(set) var endpoint: String?
    /// Bumped by every read, so one that lands after a newer one is dropped.
    @ObservationIgnored private var generation = 0
    /// When the tags were last read whole from ``endpoint``.
    @ObservationIgnored private var loadedAt: Date?

    init() {}

    /// Read the definitions from `client`'s server. Pointed at another server,
    /// it lets go of the old one's at once.
    func load(client: CodegClient) async {
        let endpoint = client.tagEndpoint
        if endpoint != self.endpoint {
            self.endpoint = endpoint
            loadedAt = nil
            tagsByID = [:]
            branchTag = BranchTagSetting()
        }
        generation += 1
        let started = generation
        async let tagRead = TagDefinitionsModel.optionalRead { try await client.listConversationTags() }
        async let branchRead = TagDefinitionsModel.optionalRead { try await client.conversationBranchTag() }
        let tags = await tagRead
        let branch = await branchRead
        guard started == generation, endpoint == self.endpoint else { return }
        adopt(tags: tags, branchTag: branch)
        if tags != nil { loadedAt = Date() }
    }

    /// ``load(client:)`` unless the definitions were read from that server
    /// within `maxAge` — what a screen asks each time it appears (a tab coming
    /// back runs its `.task` again). An edit made here is announced and read
    /// at once (`conversationTagDefinitionsDidChange`); one made elsewhere
    /// shows once the copy has aged.
    func loadIfStale(client: CodegClient, maxAge: TimeInterval = 60) async {
        if client.tagEndpoint == endpoint, let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        await load(client: client)
    }

    /// Commit one read: whichever half came back applies, a nil keeps what was
    /// there. Also the seam the tests feed.
    func adopt(tags: [ConversationTag]?, branchTag: BranchTagSetting?) {
        if let tags {
            tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let branchTag { self.branchTag = branchTag }
    }

    /// No server: nothing to resolve against.
    func reset() {
        generation += 1
        endpoint = nil
        loadedAt = nil
        tagsByID = [:]
        branchTag = BranchTagSetting()
    }

    /// What `conversation`'s chips are.
    func rowTags(for conversation: ConversationSummary) -> RowTags {
        RowTags.resolve(conversation, tagsByID: tagsByID, branchTag: branchTag)
    }

    nonisolated private static func optionalRead<T>(_ read: () async throws -> T) async -> T? {
        try? await read()
    }
}

extension Array where Element == ConversationSummary {
    /// Patch the row a confirmed tag write was for, when it is in this list and
    /// from `endpoint`'s server. True when a row changed.
    @discardableResult
    mutating func applyTagChange(_ change: ConversationTagsChange, endpoint: String?) -> Bool {
        guard change.endpoint == endpoint,
              let index = firstIndex(where: { $0.id == change.conversationID }),
              self[index].tagIds != change.tagIDs else { return false }
        self[index].tagIds = change.tagIDs
        return true
    }
}
