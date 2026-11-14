import SwiftUI
import Observation

// The composer's inline `/` (and Codex `$`) command/skill menu and `@` mention
// panel — ported from web `message-input.tsx` (the `/` menu) and
// `composer/suggestion/*` + `use-reference-search.ts` (the `@` panel, files and
// agents only). The compose bar reports text + caret; this model detects the
// trigger, gathers what the menu lists, and turns a pick into an edit.

/// What the composer menus have already seen, kept for the life of the process
/// so a cold session still offers the commands an earlier one advertised.
///
/// Keyed by server + agent + folder: an agent's commands and skills depend on
/// the workspace it runs in, and two servers can share a folder path.
@MainActor
@Observable
final class ComposerCatalog {
    static let shared = ComposerCatalog()

    struct SkillsEntry {
        var skills: [AgentSkillItem]?
        var loading = false
        /// Bumped per scan, so only the newest scan's answer lands.
        var generation = 0
    }

    /// The last command list seen per `server|agent|folder`.
    var commands: [String: [AvailableCommandInfo]] = [:]
    /// Disk skills per `server|agent|folder` (only for agents that do not
    /// advertise their skills as commands).
    var skills: [String: SkillsEntry] = [:]
    /// `acp_list_agents` per server.
    var agents: [String: [AcpAgentInfo]] = [:]
    /// Bumped per key whenever a connection pushes a command list, so a
    /// snapshot or probe read already on its way cannot land over it.
    @ObservationIgnored var commandRevisions: [String: Int] = [:]
}

/// An agent the `@` panel offers (web `agentToSuggestion`).
struct MentionAgent: Hashable, Sendable, Identifiable {
    let agentType: AgentType
    let label: String
    let detail: String?
    var id: String { agentType.rawValue }
}

/// The `@` panel's tabs, in the web's built-in order: agent first (handing a
/// subtask to another agent is what `@` is for), then files.
enum MentionTab: String, CaseIterable, Hashable, Sendable {
    case agent, file
}

/// One selectable row in either menu.
enum ComposerSuggestionRow: Hashable, Identifiable {
    /// `skill`: the agent marked the command as a skill.
    case command(AvailableCommandInfo, skill: Bool)
    case skill(AgentSkillItem, prefix: InvocationPrefix)
    case file(WorkspaceFileEntry)
    case agent(MentionAgent)

    var id: String {
        switch self {
        case .command(let command, _): return "cmd:\(command.name)"
        case .skill(let skill, _): return "skill:\(skill.scope.rawValue):\(skill.id)"
        case .file(let entry): return "file:\(entry.path)"
        case .agent(let agent): return "agent:\(agent.id)"
        }
    }
}

/// What the panel above the field shows right now.
struct ComposerPanelState: Equatable {
    enum Content: Equatable {
        /// `loading`: the agent's commands are still being fetched (a loading
        /// row, which keeps the panel open while there is nothing to list).
        /// `skillColumn`: some command is a skill, so every row keeps an icon
        /// column and the tokens line up.
        case commands(rows: [ComposerSuggestionRow], loading: Bool, skillColumn: Bool)
        /// `stale`: the file rows answer an earlier query (narrowed to this
        /// one) while the search for this one runs; they can be tapped, but
        /// Return does not pick one.
        case mention(tab: MentionTab, rows: [ComposerSuggestionRow], counts: [MentionTab: Int],
                     loading: Bool, stale: Bool, truncated: Bool, hasWorkspace: Bool)
    }

    let content: Content
    let highlighted: Int

    var rows: [ComposerSuggestionRow] {
        switch content {
        case .commands(let rows, _, _), .mention(_, let rows, _, _, _, _, _): return rows
        }
    }
}

/// How a hardware key press in the field was handled.
enum ComposerKeyOutcome {
    /// Not the panel's key: let the field have it.
    case ignored
    /// Consumed with nothing to change in the text.
    case handled
    /// Consumed: replace the text and put the caret here.
    case replace(text: String, caretUTF16: Int)
}

@MainActor
@Observable
final class ComposerSuggestionModel {

    /// The agent and folder the composer sends to. Pulled (not pushed) so it
    /// can never lag a draft's agent/folder switch.
    struct Context: Equatable {
        var agent: AgentType
        var workspaceRoot: String?
    }

    // MARK: Injected by the owner

    @ObservationIgnored var context: () -> Context = { Context(agent: .claudeCode, workspaceRoot: nil) }
    /// The agent's commands from wherever this screen can read them (live
    /// connection, conversation snapshot, or — with `allowProbe` — a probe
    /// agent). Nil when no source had any.
    @ObservationIgnored var fetchCommands: ((_ allowProbe: Bool) async -> [AvailableCommandInfo]?)?
    /// A list the owner already holds (the options sheet's probe), used only
    /// while the catalog has nothing for this agent and folder.
    @ObservationIgnored var fallbackCommands: (() -> [AvailableCommandInfo])?

    private let client: CodegClient
    private let catalog = ComposerCatalog.shared

    // MARK: Trigger state

    private(set) var trigger: ComposerTrigger?
    private var highlightedIndex = 0
    /// The tab the user picked, or nil to follow the first non-empty one.
    private var pinnedTab: MentionTab?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastCaret: Int?
    /// Closed (Escape, or a pick) on this exact text: stays closed until the
    /// text changes, so a caret move cannot reopen it.
    @ObservationIgnored private var closedOnText: String?

    // MARK: Mentions in the draft

    /// The tokens the draft's mentions read as, and what each is sent as.
    private(set) var references: [ComposerReference] = []

    // MARK: Commands / skills / agents

    /// Fetches in flight per catalog key — the `/` panel's loading row.
    private var commandFetches: [String: Int] = [:]
    /// Keys this screen already asked about, per mode (`true` = probe allowed),
    /// so a `/` that found nothing does not ask again on every keystroke.
    @ObservationIgnored private var commandsAsked: [Bool: Set<String>] = [:]
    @ObservationIgnored private var skillsScanned: Set<String> = []
    /// Observed: the agents tab shows "Searching…" while it is set and no list
    /// has arrived, and must stop when a failed request clears it.
    private var agentsRequested = false

    // MARK: File search

    struct FileResult: Equatable {
        let root: String
        let query: String
        /// As the server ranked them — up to one more than shown, the extra
        /// one only signalling "more".
        let entries: [WorkspaceFileEntry]
    }

    private var fileResult: FileResult?
    /// One consumer per screen; the generation strictly increases on it.
    private let consumerID = UUID().uuidString
    @ObservationIgnored private var fileGeneration: UInt64 = 0
    @ObservationIgnored private var fileSearchTask: Task<Void, Never>?
    @ObservationIgnored private var fileQueryRequested: (root: String, query: String)?
    /// The search the server may still be running — what closing cancels.
    @ObservationIgnored private var fileSearchOutstanding: WorkspaceSearchRequest?

    private static let fileDebounce: Duration = .milliseconds(150)
    /// Rows per group (web `MAX_PER_GROUP`); the server is asked for one more.
    static let maxPerGroup = 50
    private static let maxQueryBytes = 2048

    init(client: CodegClient) {
        self.client = client
    }

    // MARK: - Keys

    private var serverKey: String { client.baseURL.absoluteString }

    /// Where the catalog files this context's commands and skills.
    func catalogKey(_ context: Context) -> String {
        "\(serverKey)|\(context.agent.rawValue)|\(context.workspaceRoot ?? "")"
    }

    // MARK: - Commands

    /// The agent's commands as this screen knows them.
    var commands: [AvailableCommandInfo] {
        if let list = catalog.commands[catalogKey(context())] { return list }
        return fallbackCommands?() ?? []
    }

    var commandsLoading: Bool { (commandFetches[catalogKey(context())] ?? 0) > 0 }

    /// A live `available_commands` event: the agent re-advertised, and the
    /// new list replaces the old one whole.
    func adoptLiveCommands(_ list: [AvailableCommandInfo]) {
        adopt(list, key: catalogKey(context()))
    }

    /// Commands carried by a snapshot. An empty list is not taken as "none":
    /// a fresh connection reports nothing until its agent has advertised.
    func adoptSnapshotCommands(_ list: [AvailableCommandInfo]?) {
        guard let list, !list.isEmpty else { return }
        adopt(list, key: catalogKey(context()))
    }

    /// A list the connection itself pushed. Bumps the key's revision, so a
    /// fetch that was already on its way cannot land over it afterwards.
    private func adopt(_ list: [AvailableCommandInfo], key: String) {
        catalog.commands[key] = list
        catalog.commandRevisions[key, default: 0] += 1
    }

    /// The screen has its agent and folder: read what a live session already
    /// knows (never a probe), and warm the disk skills.
    func screenDidLoad() {
        let key = catalogKey(context())
        startCommandFetch(key: key, allowProbe: false)
        ensureSkills()
    }

    /// The "+" → Slash Commands sheet's list: the same one the inline menu
    /// shows, refreshed first (probing only when nothing is known yet).
    func loadCommands() async -> [AvailableCommandInfo] {
        guard fetchCommands != nil else { return commands }
        let key = catalogKey(context())
        commandFetches[key, default: 0] += 1
        await runCommandFetch(key: key, allowProbe: commands.isEmpty, revision: catalog.commandRevisions[key] ?? 0)
        return commands
    }

    private func startCommandFetch(key: String, allowProbe: Bool) {
        guard !(commandsAsked[allowProbe]?.contains(key) ?? false), fetchCommands != nil else { return }
        commandsAsked[allowProbe, default: []].insert(key)
        // Counted now, not when the task starts: the `/` that asked must see
        // the loading row on this very update, or it closes for a frame. The
        // revision is read now too — a push before the task runs is newer.
        commandFetches[key, default: 0] += 1
        let revision = catalog.commandRevisions[key] ?? 0
        Task { [weak self] in await self?.runCommandFetch(key: key, allowProbe: allowProbe, revision: revision) }
    }

    /// The fetch itself; its caller has already counted it in `commandFetches`
    /// and read the key's push `revision` when it asked.
    private func runCommandFetch(key: String, allowProbe: Bool, revision: Int) async {
        let list = await fetchCommands?(allowProbe) ?? nil
        commandFetches[key, default: 1] -= 1
        if commandFetches[key] == 0 { commandFetches[key] = nil }
        // A live update (even an empty one) arrived while this was out: it is
        // newer than whatever the snapshot or probe read.
        if let list, !list.isEmpty, (catalog.commandRevisions[key] ?? 0) == revision {
            catalog.commands[key] = list
        }
        // The cheap read found nothing while a `/` is waiting on it: go on to
        // the probe instead of closing the menu under the user.
        if !allowProbe, case .command(.slash, _, _)? = trigger,
           catalogKey(context()) == key, commands.isEmpty {
            startCommandFetch(key: key, allowProbe: true)
        }
    }

    // MARK: - Skills

    private func ensureSkills() {
        let ctx = context()
        guard ComposerInvocations.diskSkillTrigger(ctx.agent) != nil else { return }
        let key = catalogKey(ctx)
        // Once per screen: skills change on disk, and the list on screen stays
        // up until the rescan lands.
        guard !skillsScanned.contains(key) else { return }
        skillsScanned.insert(key)
        var entry = catalog.skills[key] ?? ComposerCatalog.SkillsEntry()
        entry.generation += 1
        entry.loading = true
        let generation = entry.generation
        catalog.skills[key] = entry
        let agent = ctx.agent
        let root = ctx.workspaceRoot
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.client.listAgentRuntimeSkills(agentType: agent, workspacePath: root)
            guard var current = self.catalog.skills[key], current.generation == generation else { return }
            current.loading = false
            // A failed scan keeps the last list that loaded.
            if let result { current.skills = result.supported ? result.skills : [] }
            self.catalog.skills[key] = current
            if result == nil { self.skillsScanned.remove(key) }
        }
    }

    // MARK: - Agents

    private func ensureAgents() {
        guard !agentsRequested else { return }
        agentsRequested = true
        let server = serverKey
        Task { [weak self] in
            guard let self else { return }
            guard let list = try? await self.client.listAgents() else {
                self.agentsRequested = false
                return
            }
            self.catalog.agents[server] = list
        }
    }

    /// Only enabled agents are mentionable (web `buildReferenceGroups`).
    private var mentionAgents: [MentionAgent] {
        (catalog.agents[serverKey] ?? [])
            .enumerated()
            .filter { $0.element.enabled }
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map { item in
                let agent = item.element
                return MentionAgent(agentType: agent.agentType,
                                    label: agent.name.isEmpty ? agent.agentType.label : agent.name,
                                    detail: agent.description.isEmpty ? nil : agent.description)
            }
    }

    // MARK: - Text and caret

    /// Report the field's text and caret (UTF-16; nil for a ranged selection).
    func update(text: String, caretUTF16: Int?, focused: Bool) {
        if let closed = closedOnText, closed != text { closedOnText = nil }
        // A sent (or cleared) draft takes its mentions with it.
        if text.isEmpty, !references.isEmpty { references.removeAll() }
        lastText = text
        lastCaret = caretUTF16
        if focused, closedOnText == nil, let caret = caretUTF16 {
            setTrigger(detect(text, caret: caret))
        } else {
            setTrigger(nil)
        }
    }

    /// Escape: close until the text changes.
    func dismiss() {
        closedOnText = lastText
        setTrigger(nil)
    }

    private func detect(_ text: String, caret: Int) -> ComposerTrigger? {
        guard let found = ComposerTrigger.detect(text: text, caretUTF16: caret, agent: context().agent) else { return nil }
        // The caret inside a mention picked earlier is not a new `@`.
        if case .mention(_, let range) = found, isInsideReference(text, at: range.lowerBound, caret: caret) {
            return nil
        }
        return found
    }

    private func isInsideReference(_ text: String, at start: Int, caret: Int) -> Bool {
        let units = Array(text.utf16)
        return references.contains { reference in
            let token = Array(reference.token.utf16)
            let end = start + token.count
            return end <= units.count && caret <= end && units[start..<end].elementsEqual(token)
        }
    }

    private func setTrigger(_ next: ComposerTrigger?) {
        let previous = trigger
        guard next != previous else { return }
        trigger = next
        highlightedIndex = 0
        let wasMention: Bool
        if case .mention? = previous { wasMention = true } else { wasMention = false }
        switch next {
        case .command(let prefix, _, _)?:
            if wasMention { closeFileSearch() }
            let ctx = context()
            if prefix == .slash, commands.isEmpty, !commandsLoading {
                startCommandFetch(key: catalogKey(ctx), allowProbe: true)
            }
            if ComposerInvocations.diskSkillTrigger(ctx.agent) == prefix { ensureSkills() }
        case .mention(let query, _)?:
            if !wasMention { pinnedTab = nil }
            ensureAgents()
            scheduleFileSearch(query)
        case nil:
            if wasMention { closeFileSearch() }
        }
    }

    // MARK: - Panel

    /// What to draw above the field, or nil when nothing is open.
    var panel: ComposerPanelState? {
        switch trigger {
        case .command(let prefix, let query, _)?: return commandPanel(prefix: prefix, query: query)
        case .mention(let query, _)?: return mentionPanel(query: query)
        case nil: return nil
        }
    }

    private func clamped(_ count: Int) -> Int {
        min(highlightedIndex, max(0, count - 1))
    }

    /// Web `filteredSlashCommands` + `filteredSlashSkills`: commands under `/`
    /// only, then the disk skills under the trigger their agent uses.
    private func commandPanel(prefix: InvocationPrefix, query: String) -> ComposerPanelState? {
        let ctx = context()
        let skillTrigger = ComposerInvocations.diskSkillTrigger(ctx.agent)
        let commands = self.commands
        let loading = commandsLoading
        // A commands-only `/` with nothing to list closes — unless the list is
        // still on its way. A trigger that also lists disk skills stays armed:
        // the panel fills in when the scan lands.
        if prefix == .slash, skillTrigger != .slash, commands.isEmpty, !loading { return nil }
        var commandRows: [AvailableCommandInfo] = []
        if prefix == .slash {
            commandRows = FuzzyTextMatch.rank(query, commands, primary: { $0.name })
        }
        var skillRows: [AgentSkillItem] = []
        if skillTrigger == prefix, let skills = catalog.skills[catalogKey(ctx)]?.skills, !skills.isEmpty {
            skillRows = FuzzyTextMatch.rank(
                query,
                ComposerInvocations.skillsForMenu(skills, commands: commands, trigger: prefix),
                primary: { $0.name },
                secondary: { $0.id })
        }
        let marked = ComposerInvocations.skillMarkedCommands(commands)
        var rows: [ComposerSuggestionRow] = commandRows.map { command in
            ComposerSuggestionRow.command(command, skill: marked.contains(command.name))
        }
        rows += skillRows.map { skill in ComposerSuggestionRow.skill(skill, prefix: prefix) }
        let showLoading = prefix == .slash && loading && commands.isEmpty
        guard !rows.isEmpty || showLoading else { return nil }
        return ComposerPanelState(
            content: .commands(rows: rows, loading: showLoading, skillColumn: !marked.isEmpty),
            highlighted: clamped(rows.count))
    }

    private func mentionPanel(query: String) -> ComposerPanelState {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let agentMatches = mentionAgents.filter { agent in
            q.isEmpty
                || agent.label.lowercased().contains(q)
                || agent.agentType.rawValue.lowercased().contains(q)
                || (agent.detail?.lowercased().contains(q) ?? false)
        }
        let agentRows = agentMatches.prefix(Self.maxPerGroup).map { ComposerSuggestionRow.agent($0) }

        let root = context().workspaceRoot
        let hasWorkspace = !(root ?? "").isEmpty
        var fileRows: [ComposerSuggestionRow] = []
        var truncated = false
        var fresh = false
        if hasWorkspace, let result = fileResult, result.root == root {
            fresh = result.query == query
            // The panel's substring semantics over what the server ranked
            // (web `buildReferenceGroups`); an earlier query's rows narrow to
            // this one while its own search runs.
            for entry in result.entries {
                if !q.isEmpty, !entry.name.lowercased().contains(q), !entry.path.lowercased().contains(q) { continue }
                if fileRows.count >= Self.maxPerGroup {
                    truncated = true
                    break
                }
                fileRows.append(.file(entry))
            }
        }
        let filesLoading = hasWorkspace && !fresh
        let agentsLoading = agentsRequested && catalog.agents[serverKey] == nil
        let counts: [MentionTab: Int] = [.agent: agentRows.count, .file: fileRows.count]
        // Follow the first non-empty tab until the user picks one; with both
        // empty, the files tab says it is still searching.
        let firstNonEmpty = MentionTab.allCases.first(where: { (counts[$0] ?? 0) > 0 })
        let tab: MentionTab = pinnedTab ?? firstNonEmpty ?? (hasWorkspace ? .file : .agent)
        let rows: [ComposerSuggestionRow] = tab == .agent ? agentRows : fileRows
        return ComposerPanelState(
            content: .mention(tab: tab, rows: rows, counts: counts,
                              loading: tab == .file ? filesLoading : agentsLoading,
                              stale: tab == .file && !fresh, truncated: tab == .file && truncated,
                              hasWorkspace: hasWorkspace),
            highlighted: clamped(rows.count))
    }

    /// Switch the `@` panel's tab (and keep it, whatever the query matches).
    func selectTab(_ tab: MentionTab) {
        pinnedTab = tab
        highlightedIndex = 0
    }

    // MARK: - Hardware keys

    /// A hardware key while the field has focus. `text` is the field's text
    /// right now; `composing` is whether an input method still holds marked
    /// text in it.
    func handleKey(_ key: KeyEquivalent, shift: Bool, composing: Bool = false, text: String) -> ComposerKeyOutcome {
        // Mid-composition every key is the input method's: the arrows move
        // through its candidates, Tab and Return confirm, Escape cancels (web
        // `isImeCompositionKey`). Taking one here drops the marked text.
        guard let panel, !composing else { return .ignored }
        if key == .escape {
            dismiss()
            return .handled
        }
        let rows = panel.rows
        switch panel.content {
        case .commands:
            guard !rows.isEmpty else {
                // The loading row owns the navigation keys, inserting nothing.
                let navigation: [KeyEquivalent] = [.upArrow, .downArrow, .return, .tab]
                return navigation.contains(key) ? .handled : .ignored
            }
            switch key {
            case .downArrow:
                highlightedIndex = (panel.highlighted + 1) % rows.count
                return .handled
            case .upArrow:
                highlightedIndex = (panel.highlighted - 1 + rows.count) % rows.count
                return .handled
            case .return, .tab:
                guard let result = pick(rows[panel.highlighted], in: text) else { return .handled }
                return .replace(text: result.text, caretUTF16: result.caret)
            default:
                return .ignored
            }
        case .mention(let tab, _, _, _, let stale, _, _):
            switch key {
            case .downArrow:
                if !rows.isEmpty { highlightedIndex = (panel.highlighted + 1) % rows.count }
                return .handled
            case .upArrow:
                if !rows.isEmpty { highlightedIndex = (panel.highlighted - 1 + rows.count) % rows.count }
                return .handled
            case .tab:
                let tabs = MentionTab.allCases
                let at = tabs.firstIndex(of: tab) ?? 0
                selectTab(tabs[(at + (shift ? -1 : 1) + tabs.count) % tabs.count])
                return .handled
            case .return:
                // No fresh row: decline, so the key is the field's newline.
                guard !rows.isEmpty, !stale,
                      let result = pick(rows[panel.highlighted], in: text) else { return .ignored }
                return .replace(text: result.text, caretUTF16: result.caret)
            default:
                return .ignored
            }
        }
    }

    // MARK: - Picking

    /// Apply a picked row to `text` (the field's text right now): the new text
    /// and where the caret goes. Closes the panel until the text changes again.
    func pick(_ row: ComposerSuggestionRow, in text: String) -> (text: String, caret: Int)? {
        if text != lastText {
            // The field moved on since the last report; read the trigger off
            // what it holds now, with the caret clamped into it.
            lastText = text
            lastCaret = lastCaret.map { min($0, text.utf16.count) }
        }
        guard let caret = lastCaret, let trigger = detect(lastText, caret: caret) else { return nil }
        let edit: ComposerEdit
        switch (row, trigger) {
        case (.command(let command, _), .command(_, _, let range)):
            edit = invocationEdit(ComposerInvocations.commandInvocationToken(command.name), replacing: range)
        case (.skill(let skill, let prefix), .command(_, _, let range)):
            edit = invocationEdit(prefix.rawValue + skill.id, replacing: range)
        case (.file(let entry), .mention(_, let range)):
            guard let root = context().workspaceRoot, !root.isEmpty else { return nil }
            let reference = ComposerReference.file(name: entry.name, relativePath: entry.path, workspaceRoot: root)
            register(reference)
            edit = ComposerEdit(range: range, replacement: reference.token + " ")
        case (.agent(let agent), .mention(_, let range)):
            let reference = ComposerReference.agent(agent.agentType, label: agent.label)
            register(reference)
            edit = ComposerEdit(range: range, replacement: reference.token + " ")
        default:
            return nil
        }
        guard let text = edit.apply(to: lastText) else { return nil }
        closedOnText = text
        lastText = text
        lastCaret = edit.caretAfter
        setTrigger(nil)
        return (text, edit.caretAfter)
    }

    /// Web `replaceTriggerWithReference`: the `/…`·`$…` token before the caret
    /// becomes the invocation, plus a space unless whitespace already follows.
    private func invocationEdit(_ token: String, replacing range: Range<Int>) -> ComposerEdit {
        let units = Array(lastText.utf16)
        let followedBySpace = range.upperBound < units.count && JSWhitespace.contains(units[range.upperBound])
        return ComposerEdit(range: range, replacement: token + (followedBySpace ? "" : " "))
    }

    // MARK: - Mentions on the wire

    private func register(_ reference: ComposerReference) {
        references.removeAll { $0.token == reference.token }
        references.append(reference)
    }

    /// The draft as it is sent: each mention token as its Markdown link.
    func encode(_ text: String) -> String {
        ComposerReferenceCodec.encode(text, references: references)
    }

    /// A sent message coming back to the composer: its links become tokens
    /// again (and are registered), so re-sending reproduces the original.
    func restore(_ wire: String) -> String {
        let decoded = ComposerReferenceCodec.decode(wire, workspaceRoot: context().workspaceRoot)
        decoded.references.forEach(register)
        return decoded.text
    }

    // MARK: - File search

    private func scheduleFileSearch(_ query: String) {
        guard let root = context().workspaceRoot, !root.isEmpty else { return }
        if let requested = fileQueryRequested, requested.root == root, requested.query == query { return }
        fileQueryRequested = (root, query)
        // Whatever was pending answers another query now — `@ab` backspaced
        // to `@a` must not let the `ab` search land over `a`'s results.
        fileSearchTask?.cancel()
        fileSearchTask = nil
        if let result = fileResult, result.root == root, result.query == query { return }
        guard query.utf8.count <= Self.maxQueryBytes else {
            fileResult = FileResult(root: root, query: query, entries: [])
            return
        }
        fileSearchTask = Task { [weak self] in
            try? await Task.sleep(for: ComposerSuggestionModel.fileDebounce)
            guard let self, !Task.isCancelled else { return }
            self.fileGeneration &+= 1
            let request = WorkspaceSearchRequest(consumerId: self.consumerID, generation: self.fileGeneration)
            self.fileSearchOutstanding = request
            // A failed search reads as no matches (web: `.catch(() => [])`).
            let entries = (try? await self.client.searchWorkspaceFiles(
                path: root, query: query, limit: ComposerSuggestionModel.maxPerGroup + 1, request: request)) ?? []
            // Cancelled here is only the local wait: the server may still be
            // running it, so it stays outstanding for `closeFileSearch`.
            guard !Task.isCancelled else { return }
            if self.fileSearchOutstanding == request { self.fileSearchOutstanding = nil }
            guard request.generation == self.fileGeneration,
                  let requested = self.fileQueryRequested, requested.root == root, requested.query == query
            else { return }
            self.fileResult = FileResult(root: root, query: query, entries: entries)
        }
    }

    /// The panel closed: stop waiting, and tell the server to stop too. Only
    /// here — a newer query already supersedes an older one server-side.
    private func closeFileSearch() {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        fileQueryRequested = nil
        fileResult = nil
        if let outstanding = fileSearchOutstanding {
            fileSearchOutstanding = nil
            let client = self.client
            Task { try? await client.cancelWorkspaceFileSearch(request: outstanding) }
        }
    }

    /// The screen went away.
    func teardown() {
        setTrigger(nil)
        closeFileSearch()
    }
}

/// SwiftUI's `TextSelection` (String.Index based) to and from the UTF-16
/// offsets the trigger logic works in. Converted the moment the field reports
/// it, and validated against the current text: an index left over from an
/// earlier string must never be used to subscript this one.
enum ComposerCaret {
    /// The caret as a UTF-16 offset into `text`: the insertion point; the end
    /// of the text when the field reports no selection (or several ranges);
    /// nil for a ranged selection — which opens no menu, as on the web — or an
    /// index that does not fit `text`.
    static func offset(of selection: TextSelection?, in text: String) -> Int? {
        guard let selection else { return text.utf16.count }
        switch selection.indices {
        case .selection(let range):
            guard range.isEmpty else { return nil }
            return offset(of: range.lowerBound, in: text)
        case .multiSelection:
            return text.utf16.count
        @unknown default:
            return text.utf16.count
        }
    }

    static func offset(of index: String.Index, in text: String) -> Int? {
        guard index >= text.startIndex, index <= text.endIndex,
              let aligned = String.Index(index, within: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: aligned)
    }

    static func index(utf16 offset: Int, in text: String) -> String.Index {
        let clamped = max(0, min(offset, text.utf16.count))
        return text.utf16.index(text.utf16.startIndex, offsetBy: clamped)
    }
}
