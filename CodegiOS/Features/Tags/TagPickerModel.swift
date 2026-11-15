import Foundation
import Observation

/// The tag writes owed to one conversation on one server, and its single
/// writer. Shared by every picker that shows that conversation (the Chats row
/// and the session screen, a second window on iPad): two writers racing each
/// other's deltas is exactly what this exists to prevent.
@MainActor
@Observable
final class TagWriteSession {
    let endpoint: String
    let conversationID: Int
    /// The calls the writes go out on. Re-pointed by every bind, so a reopen
    /// with a fresh client (an edited token) sends the next write with it.
    @ObservationIgnored fileprivate(set) var api: any ConversationTagsAPI
    fileprivate(set) var assignment: TagAssignment
    /// A write is out; the next waits for it.
    fileprivate(set) var isWriting = false
    /// Tags being created for this conversation: each becomes a write when it
    /// exists, so they count as work it still owes.
    fileprivate(set) var creating = 0
    /// The last refusal, for whichever picker shows this session.
    var failure: String?
    /// Pickers showing this session right now.
    @ObservationIgnored fileprivate var holders = 0

    fileprivate init(endpoint: String, conversationID: Int, api: any ConversationTagsAPI, confirmed: Set<Int>) {
        self.endpoint = endpoint
        self.conversationID = conversationID
        self.api = api
        self.assignment = TagAssignment(confirmed: confirmed)
    }

    /// What the user wants on the conversation — shown at once.
    var desired: Set<Int> { assignment.desired }

    /// Owes the server nothing: no write out, no create out, nothing unsent.
    var isIdle: Bool { !isWriting && creating == 0 && assignment.nextWrite() == nil }
}

/// Every conversation's tag writer, one per (server, conversation), for the
/// app's life. A conversation still owing writes keeps its one session, which a
/// reopen takes over instead of starting a second; one with nothing owed and
/// no picker showing it is forgotten, so the next open starts from the
/// caller's (fresher) summary. Port of Android `TagPickerController`'s
/// session table, lifted out of the picker so the list and the session screen
/// share it.
@MainActor
final class TagWriteRegistry {
    static let shared = TagWriteRegistry()

    /// Told of every write the server confirmed, with the row as it now stands.
    var onConfirmed: (TagWriteSession, ConversationSummary) -> Void = { session, summary in
        NotificationCenter.default.post(
            name: .conversationTagsDidChange,
            object: ConversationTagsChange(endpoint: session.endpoint, conversationID: summary.id, tagIDs: summary.tagIds)
        )
    }
    /// Told when a tag was created, so lists re-read the definitions.
    var onTagCreated: (ConversationTag) -> Void = { _ in
        NotificationCenter.default.post(name: .conversationTagDefinitionsDidChange, object: nil)
    }

    private var sessions: [String: TagWriteSession] = [:]

    init() {}

    private static func key(_ endpoint: String, _ conversationID: Int) -> String {
        "\(endpoint)|\(conversationID)"
    }

    /// The session a picker opening `conversation` on `endpoint` shows and
    /// edits. One still held or still writing is taken over as it stands —
    /// what it holds is newer than a summary the caller may not have refetched
    /// yet; otherwise the caller's summary is the latest word.
    func bind(endpoint: String, conversation: ConversationSummary, api: any ConversationTagsAPI) -> TagWriteSession {
        let key = Self.key(endpoint, conversation.id)
        let session: TagWriteSession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = TagWriteSession(endpoint: endpoint, conversationID: conversation.id,
                                      api: api, confirmed: Set(conversation.tagIds))
            sessions[key] = session
        }
        session.api = api
        session.holders += 1
        // A refusal some earlier opening was shown is not news to this one.
        session.failure = nil
        return session
    }

    /// A picker stopped showing `session`.
    func release(_ session: TagWriteSession) {
        session.holders = max(0, session.holders - 1)
        prune()
    }

    /// Put `tagID` on, or take it off. Shown at once; the write follows.
    func toggle(_ tagID: Int, in session: TagWriteSession) {
        session.assignment.toggle(tagID)
        pump(session)
    }

    /// Create a tag and put it on `session`'s conversation — whatever the
    /// picker shows by the time it exists. Counted as owed work from THIS call,
    /// synchronously: a reopen racing the request must find the session busy,
    /// or it would start a second writer. `completion` gets the tag (nil after
    /// a refusal, which `failure` then names).
    func create(name: String, folderID: Int?, color: String, in session: TagWriteSession,
                completion: @escaping @MainActor (ConversationTag?) -> Void) {
        session.creating += 1
        Task { [weak self] in
            var created: ConversationTag?
            do {
                let tag = try await session.api.createConversationTag(folderId: folderID, name: name, color: color)
                created = tag
                self?.onTagCreated(tag)
                session.assignment.turnOn(tag.id)
                self?.pump(session)
            } catch {
                session.failure = String(localized: "Couldn't create the tag: \(TagWriteRegistry.describe(error))")
            }
            session.creating -= 1
            completion(created)
            self?.prune()
        }
    }

    /// Send what `session` still owes the server, one write at a time.
    private func pump(_ session: TagWriteSession) {
        guard !session.isWriting, let write = session.assignment.nextWrite() else { return }
        session.isWriting = true
        Task { [weak self] in
            do {
                let summary = try await session.api.updateConversationTags(
                    conversationId: session.conversationID, add: write.add, remove: write.remove)
                session.assignment.succeeded(write, server: Set(summary.tagIds))
                self?.onConfirmed(session, summary)
            } catch {
                session.assignment.failed(write)
                session.failure = String(localized: "Couldn't update the conversation's tags: \(TagWriteRegistry.describe(error))")
            }
            session.isWriting = false
            // Toggles made while this was out go next; after a refusal only
            // those remain.
            self?.pump(session)
            self?.prune()
        }
    }

    /// Forget the sessions that owe nothing and that no picker shows.
    private func prune() {
        sessions = sessions.filter { $0.value.holders > 0 || !$0.value.isIdle }
    }

    /// Whether the registry still holds a session for this conversation —
    /// for tests of the pruning rule.
    func hasSession(endpoint: String, conversationID: Int) -> Bool {
        sessions[Self.key(endpoint, conversationID)] != nil
    }

    fileprivate static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}

/// One tag picker sheet (web `ConversationTagPickerPanel`): which conversation
/// it shows, the server's tags and folders, and the writer it edits through.
///
/// Nothing is actionable until this opening has bound its session and read the
/// tags, so nothing can reach a server or conversation it isn't showing. Each
/// opening takes a sequence number; a read that lands after a newer opening —
/// another conversation, or another server — binds nothing.
@MainActor
@Observable
final class TagPickerModel {
    private let registry: TagWriteRegistry

    private(set) var conversation: ConversationSummary?
    /// Every tag the server has; nil while loading.
    private(set) var tags: [ConversationTag]?
    private(set) var folders: [FolderDetail] = []
    /// The session this opening edits; nil until bound, and again after the
    /// tags failed to load.
    private(set) var session: TagWriteSession?
    private(set) var loadError: String?
    @ObservationIgnored private var openSeq = 0

    init(registry: TagWriteRegistry) {
        self.registry = registry
    }

    convenience init() {
        self.init(registry: .shared)
    }

    /// What shows as on: the user's wish, ahead of the writes.
    var desired: Set<Int> { session?.desired ?? Set(conversation?.tagIds ?? []) }
    /// A tag is being created for this conversation.
    var isCreating: Bool { (session?.creating ?? 0) > 0 }
    var error: String? { loadError ?? session?.failure }
    /// The tags can be toggled.
    var isReady: Bool { session != nil && tags != nil }

    /// The folder whose own tags this conversation is offered (none for a chat).
    var scope: Int? {
        guard let id = conversation?.folderId else { return nil }
        return ConversationTags.scopeFolderID(folders.first { $0.id == id })
    }

    var scopeName: String? {
        guard let scope else { return nil }
        return folders.first { $0.id == scope }?.name
    }

    /// Show `conversation`, as the caller has it — its folder too, which a move
    /// may have changed — and bind its writer on `endpoint`.
    func open(_ conversation: ConversationSummary, api: any ConversationTagsAPI, endpoint: String) {
        openSeq += 1
        let seq = openSeq
        if let previous = session { registry.release(previous) }
        self.conversation = conversation
        tags = nil
        folders = []
        loadError = nil
        let bound = registry.bind(endpoint: endpoint, conversation: conversation, api: api)
        session = bound
        Task { [weak self] in
            do {
                async let tagsRequest = api.listConversationTags()
                async let foldersRequest = api.listFolders()
                let tags = try await tagsRequest
                // Folders only name the scope; without them the global tags still work.
                let folders = (try? await foldersRequest) ?? []
                guard let self, seq == self.openSeq, self.session === bound else { return }
                self.tags = tags
                self.folders = folders
            } catch {
                guard let self, seq == self.openSeq, self.session === bound else { return }
                // Without the tag list there is nothing to toggle: the error is
                // all it shows.
                self.registry.release(bound)
                self.session = nil
                self.tags = []
                self.loadError = String(localized: "Couldn't load tags: \(TagWriteRegistry.describe(error))")
            }
        }
    }

    /// Read the tag definitions again — the manager renamed, recoloured or
    /// deleted some — keeping this opening's binding. Bound to the opening like
    /// the first read: one that lands after a newer opening is dropped.
    func refreshTags() {
        guard let bound = session, tags != nil else { return }
        let seq = openSeq
        let api = bound.api
        Task { [weak self] in
            guard let tags = try? await api.listConversationTags(),
                  let self, seq == self.openSeq, self.session === bound else { return }
            self.tags = tags
        }
    }

    /// The sheet went away.
    func close() {
        openSeq += 1
        if let session { registry.release(session) }
        session = nil
    }

    func dismissError() {
        loadError = nil
        session?.failure = nil
    }

    /// Put `tag` on, or take it off.
    func toggle(_ tag: ConversationTag) {
        guard let session, tags != nil, conversation?.id == session.conversationID else { return }
        registry.toggle(tag.id, in: session)
    }

    /// Create a tag named `name` — global, or in this conversation's folder —
    /// and put it on. It starts on the first colour its neighbours don't use.
    func create(name: String, global: Bool) {
        guard let session, let tags, conversation?.id == session.conversationID, session.creating == 0 else { return }
        let trimmed = ConversationTags.cappedName(name)
        guard !trimmed.isEmpty else { return }
        let folderScope: Int?
        if global {
            folderScope = nil
        } else {
            guard let scope else { return }
            folderScope = scope
        }
        let neighbours = tags.filter { $0.folderId == nil || $0.folderId == folderScope }
        registry.create(name: trimmed, folderID: folderScope,
                        color: ConversationTags.nextColor(neighbours: neighbours), in: session) { [weak self] tag in
            // Only into a list this opening has already read: a reopen of the
            // same conversation shares the session, and seeding its still-
            // unread list from here would make it ready before its own read.
            // (The registry puts the tag on either way; a later read lists it.)
            guard let tag, let self, self.session === session, var current = self.tags else { return }
            if !current.contains(where: { $0.id == tag.id }) { current.append(tag) }
            self.tags = current
        }
    }
}
