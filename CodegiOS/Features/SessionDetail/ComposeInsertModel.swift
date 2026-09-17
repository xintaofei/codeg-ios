import SwiftUI
import Observation

/// Backs the compose-bar "+" menu's three insert sources — Quick Messages,
/// Expert Skills, and Slash Commands — mirroring the web client's add-menu
/// (`message-input.tsx`). Loading is on demand (when a picker sheet opens) via
/// closures the owner wires to `CodegClient`; selecting an item produces a pure
/// draft transform applied by the compose bar.
@MainActor
@Observable
final class ComposeInsertModel {

    /// The three text-insert sources in the "+" menu.
    enum Source: String, Identifiable, CaseIterable {
        case quickMessages, experts, slashCommands
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .quickMessages: return "Quick Messages"
            case .experts: return "Expert Skills"
            case .slashCommands: return "Slash Commands"
            }
        }
        var systemImage: String {
            switch self {
            case .quickMessages: return "text.bubble"
            case .experts: return "sparkles"
            case .slashCommands: return "slash.circle"
            }
        }
    }

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    /// The agent in context — drives the expert-mention prefix (`$` for Codex,
    /// `/` otherwise) and is the agent whose experts are listed.
    var agentType: AgentType = .claudeCode

    // Loaders injected by the owner (wired to the client + this conversation).
    var loadQuickMessagesAction: (() async throws -> [QuickMessage])?
    var loadExpertsAction: (() async throws -> [ExpertListItem])?
    /// The GLOBAL built-in expert catalog (`experts_list`), used only to build the
    /// known-expert id set for the replace-prefix logic (the web's `expertIdSet`).
    var loadBuiltInExpertsAction: (() async throws -> [ExpertListItem])?
    var loadCommandsAction: (() async throws -> [AvailableCommandInfo])?
    /// Backs the inline `@`-mention popup (not one of the "+" menu `Source`s,
    /// which are sheet-presented — this loads lazily the first time the compose
    /// bar detects a live `@token`).
    var loadAgentsAction: (() async throws -> [AcpAgentInfo])?

    private(set) var quickMessages: [QuickMessage] = []
    private(set) var experts: [ExpertListItem] = []
    private(set) var commands: [AvailableCommandInfo] = []
    private(set) var agents: [AcpAgentInfo] = []
    private var agentsTask: Task<Void, Never>?

    /// Ids treated as "known experts" when deciding whether to replace an existing
    /// mention prefix. Mirrors the web's `expertIdSet` (built from the built-in
    /// catalog, of which agent-linked experts are a subset); the agent's own
    /// experts are folded in as a fallback if the catalog read fails.
    private(set) var knownExpertIDs: Set<String> = []

    private(set) var phases: [Source: Phase] = [:]
    private var tasks: [Source: Task<Void, Never>] = [:]
    /// Memoized (on success) global built-in expert ids, used for both the
    /// replace-prefix known set and the slash-command filter.
    private var builtInIDs: Set<String>?

    private let client: CodegClient

    init(client: CodegClient) {
        self.client = client
    }

    func phase(_ source: Source) -> Phase { phases[source] ?? .idle }

    /// True when a source has loaded and produced no items (drives an empty state).
    func isEmpty(_ source: Source) -> Bool {
        switch source {
        case .quickMessages: return quickMessages.isEmpty
        case .experts: return experts.isEmpty
        case .slashCommands: return visibleCommands.isEmpty
        }
    }

    /// Slash commands with expert-backed commands removed (web parity:
    /// `availableCommands.filter(cmd => !expertIdSet.has(cmd.name))`). Reactive —
    /// re-filters when `knownExpertIDs` updates.
    var visibleCommands: [AvailableCommandInfo] {
        commands.filter { !knownExpertIDs.contains($0.name) }
    }

    // MARK: - Load

    /// Load (or refresh) a source. Keeps any previously loaded items visible while
    /// refreshing, so reopening a picker shows instantly then updates.
    func load(_ source: Source) {
        if case .loading = phase(source) { return }
        phases[source] = .loading
        tasks[source]?.cancel()
        tasks[source] = Task { [weak self] in
            guard let self else { return }
            do {
                switch source {
                case .quickMessages:
                    let list = try await (self.loadQuickMessagesAction?() ?? [])
                    if Task.isCancelled { return }
                    self.quickMessages = list.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
                case .experts:
                    // Fetch the agent's experts and the global built-in known set
                    // CONCURRENTLY, then publish the list and the known set TOGETHER
                    // (no await between) so a row can never be tapped while the
                    // known set is still stale — which would stack an existing
                    // built-in prefix instead of replacing it.
                    async let agentList = (self.loadExpertsAction?() ?? [])
                    let builtIn = await self.builtInKnownIDs()
                    let list = try await agentList
                    if Task.isCancelled { return }
                    self.experts = list.sorted {
                        (Self.rank($0.metadata.category), $0.metadata.sortOrder, $0.metadata.id)
                            < (Self.rank($1.metadata.category), $1.metadata.sortOrder, $1.metadata.id)
                    }
                    self.knownExpertIDs = builtIn.union(list.map { $0.metadata.id })
                case .slashCommands:
                    // Resolve the known-expert set too, so the filter (below /
                    // `visibleCommands`) can hide expert-backed commands even when
                    // Expert Skills was never opened (web parity).
                    async let cmds = (self.loadCommandsAction?() ?? [])
                    let known = await self.builtInKnownIDs()
                    let list = try await cmds
                    if Task.isCancelled { return }
                    self.knownExpertIDs.formUnion(known)
                    self.commands = list
                }
                if Task.isCancelled { return }
                self.phases[source] = .loaded
            } catch is CancellationError {
                // superseded / torn down
            } catch {
                if Task.isCancelled { return }
                self.phases[source] = .failed(Self.describe(error))
            }
        }
    }

    /// The global built-in expert ids (the web's `expertIdSet`), memoized on
    /// success. A transient failure returns an empty set without memoizing, so a
    /// later load retries rather than permanently disabling the known set.
    private func builtInKnownIDs() async -> Set<String> {
        if let ids = builtInIDs { return ids }
        guard let action = loadBuiltInExpertsAction else { return [] }
        guard let list = try? await action() else { return [] }
        let ids = Set(list.map { $0.metadata.id })
        builtInIDs = ids
        return ids
    }

    func teardown() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        agentsTask?.cancel()
    }

    // MARK: - Inline `@`-mention (agents)

    /// Loads the agent list once and memoizes it; safe to call on every
    /// keystroke while a mention token is live.
    func loadAgentsIfNeeded() {
        guard agents.isEmpty, agentsTask == nil else { return }
        agentsTask = Task { [weak self] in
            guard let self, let action = self.loadAgentsAction else { return }
            guard let list = try? await action() else { return }
            if Task.isCancelled { return }
            self.agents = list.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        }
    }

    /// Mentionable agents matching `query` (case-insensitive prefix/substring on
    /// name), limited to enabled + available — mirroring the web's filter in
    /// `use-reference-search.ts`.
    func matchingAgents(for query: String) -> [AcpAgentInfo] {
        let pool = agents.filter { $0.enabled && $0.available }
        guard !query.isEmpty else { return pool }
        let q = query.lowercased()
        return pool.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: - Insertion (pure draft transforms)

    /// The expert-mention prefix for the current agent (`$` for Codex, `/` else),
    /// matching the web's `expertPrefix`.
    var expertPrefix: String { agentType == .codex ? "$" : "/" }

    /// Append a quick-message template to the draft (a separating space is added
    /// when needed so it doesn't run into existing text).
    func draftAppendingMessage(_ content: String, to draft: String) -> String {
        guard !content.isEmpty else { return draft }
        if draft.isEmpty { return content }
        let needsSpace = !(draft.last?.isWhitespace ?? false)
        return draft + (needsSpace ? " " : "") + content
    }

    /// Append a slash command (`/<name> `) to the draft, mirroring the web's
    /// `handleSlashPopoverSelect` spacing (a leading space when needed).
    func draftAppendingCommand(_ name: String, to draft: String) -> String {
        let needsSpace = !draft.isEmpty && !(draft.last?.isWhitespace ?? false)
        return draft + (needsSpace ? " " : "") + "/\(name) "
    }

    /// Prepend an expert mention (`<prefix><id> `) to the draft, replacing an
    /// existing expert prefix already at the front so they don't stack — mirroring
    /// the web's `handleExpertPopoverSelect`.
    func draftApplyingExpert(_ id: String, to draft: String) -> String {
        let insertion = "\(expertPrefix)\(id) "
        var base = draft
        if let found = firstExpertPrefix(in: draft), knownExpertIDs.contains(found.id) {
            base = String(draft[found.end...])
        }
        return base.isEmpty ? insertion : insertion + base
    }

    /// Find a leading `<prefix><id><whitespace>` token in the draft, returning the
    /// id and the index just past the trailing whitespace (so the caller can strip
    /// the whole token). Matches the web regex `^<prefix>([A-Za-z0-9_-]+)\s`.
    private func firstExpertPrefix(in draft: String) -> (id: String, end: String.Index)? {
        guard draft.hasPrefix(expertPrefix) else { return nil }
        var i = draft.index(draft.startIndex, offsetBy: expertPrefix.count)
        var id = ""
        while i < draft.endIndex {
            let ch = draft[i]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                id.append(ch); i = draft.index(after: i)
            } else { break }
        }
        guard !id.isEmpty, i < draft.endIndex, draft[i].isWhitespace else { return nil }
        return (id, draft.index(after: i))
    }

    /// Find a live `@token` at the very end of the draft — the trailing `@`
    /// (preceded by start-of-string or whitespace) through the rest of the
    /// string, so long as that rest contains no whitespace yet (still being
    /// typed). Operates on the tail only: the plain `TextField` this backs
    /// exposes no caret position, so an `@` earlier in an already-finished
    /// message won't retrigger the popup — matching the common case of typing
    /// a mention as you go.
    func trailingMentionToken(in draft: String) -> (token: String, start: String.Index)? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex != draft.startIndex {
            let before = draft.index(before: atIndex)
            guard draft[before].isWhitespace else { return nil }
        }
        let token = draft[draft.index(after: atIndex)...]
        guard !token.contains(where: { $0.isWhitespace }) else { return nil }
        return (String(token), atIndex)
    }

    /// Replace the trailing `@token` with the agent's markdown reference badge
    /// (`[@Name](codeg://agent/<type>)`), matching the desktop/web format the
    /// server parses into a delegation — mirroring `adapters.ts`'s
    /// `agentToSuggestion` insertion. Falls back to appending when the trailing
    /// token can't be found (e.g. called from outside the popup flow).
    func draftInsertingAgentMention(_ agent: AcpAgentInfo, to draft: String) -> String {
        let badge = "[@\(agent.name)](codeg://agent/\(agent.agentType.rawValue)) "
        guard let found = trailingMentionToken(in: draft) else {
            let needsSpace = !draft.isEmpty && !(draft.last?.isWhitespace ?? false)
            return draft + (needsSpace ? " " : "") + badge
        }
        return String(draft[draft.startIndex..<found.start]) + badge
    }

    // MARK: - Helpers

    /// Web's expert category sort order (`CATEGORY_SORT`); unknown categories sort last.
    private static let categoryOrder = ["discovery", "planning", "execution", "quality", "debugging", "review", "meta"]
    private static func rank(_ category: String) -> Int {
        categoryOrder.firstIndex(of: category) ?? categoryOrder.count
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}
