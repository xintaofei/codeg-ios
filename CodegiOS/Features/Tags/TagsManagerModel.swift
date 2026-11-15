import Foundation
import Observation

/// Manage tags (web `ConversationTagsManager`): the branch tag setting, the
/// global tags, and one folder's tags at a time — create, rename / recolour,
/// delete, reorder. Each change is the server's to make; lists are told to
/// re-read the definitions after it.
///
/// One change at a time (`isSaving`), and a read only lands if no change was
/// made while it was out: a refetch after a reorder must not erase a tag
/// created in the meantime.
@MainActor
@Observable
final class TagsManagerModel {
    private let client: CodegClient

    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var tags: [ConversationTag] = []
    /// Nil when the server's setting couldn't be read (the section hides).
    private(set) var branchTag: BranchTagSetting?
    /// Top-level open folders: the ones that can own tags.
    private(set) var folders: [FolderDetail] = []
    var selectedFolderID: Int?
    /// A change's failure, said in the list (or under the open form).
    var error: String?
    private(set) var isSaving = false

    /// Bumped by every change made here. A read started before one would hand
    /// back a list without it (or with what it removed).
    @ObservationIgnored private var generation = 0

    init(client: CodegClient) {
        self.client = client
    }

    /// One scope's tags in their order (nil = global).
    func scopeTags(_ scope: Int?) -> [ConversationTag] {
        tags.filter { $0.folderId == scope }.sorted(by: ConversationTags.precedes)
    }

    /// The colour a new tag in `scope` starts on.
    func suggestedColor(for scope: Int?) -> String {
        ConversationTags.nextColor(neighbours: tags.filter { $0.folderId == nil || $0.folderId == scope })
    }

    func load() async {
        isLoading = true
        loadError = nil
        let started = generation
        async let tagsRequest = client.listConversationTags()
        async let branchRequest = client.conversationBranchTag()
        async let foldersRequest = client.listOpenFolders()
        do {
            let tags = try await tagsRequest
            let branch = try? await branchRequest
            let open = (try? await foldersRequest) ?? []
            let roots = FolderVisibility.filterTopLevel(open).filter { $0.kind == .regular }
            isLoading = false
            guard generation == started else { return }
            self.tags = tags
            branchTag = branch
            folders = roots
            if !roots.contains(where: { $0.id == selectedFolderID }) {
                selectedFolderID = roots.first?.id
            }
        } catch {
            isLoading = false
            guard !(error is CancellationError) else { return }
            loadError = Self.describe(error)
        }
    }

    /// Create in `scope` (nil = global). True once saved; false keeps the form
    /// open with the server's reason under it.
    func create(scope: Int?, name: String, color: String) async -> Bool {
        let name = ConversationTags.cappedName(name)
        return await mutate(failure: { String(localized: "Couldn't create the tag: \($0)") }) {
            let tag = try await self.client.createConversationTag(folderId: scope, name: name, color: color)
            self.tags.append(tag)
        }
    }

    /// Send only what changed.
    func update(_ tag: ConversationTag, name: String, color: String) async -> Bool {
        let trimmed = ConversationTags.cappedName(name)
        let newName = trimmed == tag.name ? nil : trimmed
        let newColor = color.caseInsensitiveCompare(tag.color) == .orderedSame ? nil : color
        guard newName != nil || newColor != nil else { return true }
        return await mutate(failure: { String(localized: "Couldn't save the tag: \($0)") }) {
            let saved = try await self.client.updateConversationTag(tagId: tag.id, name: newName, color: newColor)
            self.tags = self.tags.map { $0.id == saved.id ? saved : $0 }
        }
    }

    func delete(_ tag: ConversationTag) async {
        _ = await mutate(failure: { String(localized: "Couldn't delete the tag: \($0)") }) {
            try await self.client.deleteConversationTag(tagId: tag.id)
            self.tags.removeAll { $0.id == tag.id }
        }
    }

    /// Move `tag` one place up (`by` -1) or down (+1) in its scope, sending
    /// the scope's whole order. Shown at once; the server's order replaces it.
    func move(_ tag: ConversationTag, by offset: Int) async {
        guard let ids = TagOrder.shifting(scopeTags(tag.folderId).map(\.id), tag.id, by: offset) else { return }
        await saveOrder(ids)?.value
    }

    /// A drag in `scope`'s rows (`.onMove`'s offsets, over ``scopeTags(_:)``),
    /// sending the scope's whole order. The new order is in place before this
    /// returns — synchronously, so the list doesn't draw the row back where it
    /// was first — and the server's order replaces it once saved. Nothing while
    /// another change is out: the row goes back.
    @discardableResult
    func reorder(scope: Int?, fromOffsets source: IndexSet, toOffset destination: Int) -> Task<Void, Never>? {
        guard let ids = TagOrder.moving(scopeTags(scope).map(\.id), fromOffsets: source, toOffset: destination)
        else { return nil }
        return saveOrder(ids)
    }

    /// Claim the one change slot now, show `ids` as their scope's order, and
    /// send it. Nil (nothing shown) while another change is out.
    private func saveOrder(_ ids: [Int]) -> Task<Void, Never>? {
        guard claim() else { return nil }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 + 1) })
        tags = tags.map { tag in
            guard let position = order[tag.id] else { return tag }
            var moved = tag
            moved.sortOrder = position
            return moved
        }
        return Task {
            _ = await self.perform(failure: { String(localized: "Couldn't save the tag order: \($0)") },
                                   refetchAfter: true) {
                try await self.client.reorderConversationTags(tagIds: ids)
            }
        }
    }

    /// Shown at once; a refusal puts the previous setting back.
    func setBranchTag(enabled: Bool, color: String) async {
        let previous = branchTag
        branchTag = BranchTagSetting(enabled: enabled, color: color)
        _ = await mutate(failure: { String(localized: "Couldn't save the branch tag: \($0)") },
                         onFailure: { self.branchTag = previous }) {
            self.branchTag = try await self.client.updateConversationBranchTag(enabled: enabled, color: color)
        }
    }

    func dismissError() { error = nil }

    private func mutate(
        failure: (String) -> String,
        refetchAfter: Bool = false,
        onFailure: () -> Void = {},
        _ body: () async throws -> Void
    ) async -> Bool {
        guard claim() else { return false }
        return await perform(failure: failure, refetchAfter: refetchAfter, onFailure: onFailure, body)
    }

    /// Take the one change slot, or false while another change holds it. From
    /// here a read started earlier can't land over what this change shows.
    private func claim() -> Bool {
        guard !isSaving else { return false }
        generation += 1
        isSaving = true
        error = nil
        return true
    }

    /// Run a change that holds the slot (``claim()``), and free it after.
    private func perform(
        failure: (String) -> String,
        refetchAfter: Bool = false,
        onFailure: () -> Void = {},
        _ body: () async throws -> Void
    ) async -> Bool {
        defer { isSaving = false }
        do {
            try await body()
            NotificationCenter.default.post(name: .conversationTagDefinitionsDidChange, object: nil)
            if refetchAfter { await reloadAfterChange() }
            return true
        } catch {
            onFailure()
            self.error = failure(Self.describe(error))
            // What the server holds now, whatever this screen assumed.
            if refetchAfter { await reloadAfterChange() }
            return false
        }
    }

    /// The re-read a change asks for: it must land, so it counts as started
    /// after that change.
    private func reloadAfterChange() async {
        guard let fresh = try? await client.listConversationTags() else { return }
        tags = fresh
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}
