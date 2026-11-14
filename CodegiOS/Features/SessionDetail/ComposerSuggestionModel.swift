import SwiftUI
import Observation

// The composer's inline `/` (and Codex `$`) command/skill menu — ported from
// web `message-input.tsx`. The compose bar reports text + caret; this model
// detects the trigger, gathers what the menu lists, and turns a pick into an
// edit.

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
}

/// One selectable row in the menu.
enum ComposerSuggestionRow: Hashable, Identifiable {
    /// `skill`: the agent marked the command as a skill.
    case command(AvailableCommandInfo, skill: Bool)
    case skill(AgentSkillItem, prefix: InvocationPrefix)

    var id: String {
        switch self {
        case .command(let command, _): return "cmd:\(command.name)"
        case .skill(let skill, _): return "skill:\(skill.scope.rawValue):\(skill.id)"
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
    }

    let content: Content
    let highlighted: Int

    var rows: [ComposerSuggestionRow] {
        switch content {
        case .commands(let rows, _, _): return rows
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
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastCaret: Int?
    /// Closed (Escape, or a pick) on this exact text: stays closed until the
    /// text changes, so a caret move cannot reopen it.
    @ObservationIgnored private var closedOnText: String?

    // MARK: Commands / skills

    /// Fetches in flight per catalog key — the `/` panel's loading row.
    private var commandFetches: [String: Int] = [:]
    /// Keys this screen already asked about, per mode (`true` = probe allowed),
    /// so a `/` that found nothing does not ask again on every keystroke.
    @ObservationIgnored private var commandsAsked: [Bool: Set<String>] = [:]
    @ObservationIgnored private var skillsScanned: Set<String> = []

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
        catalog.commands[catalogKey(context())] = list
    }

    /// Commands carried by a snapshot. An empty list is not taken as "none":
    /// a fresh connection reports nothing until its agent has advertised.
    func adoptSnapshotCommands(_ list: [AvailableCommandInfo]?) {
        guard let list, !list.isEmpty else { return }
        catalog.commands[catalogKey(context())] = list
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
        await runCommandFetch(key: key, allowProbe: commands.isEmpty)
        return commands
    }

    private func startCommandFetch(key: String, allowProbe: Bool) {
        guard !(commandsAsked[allowProbe]?.contains(key) ?? false), fetchCommands != nil else { return }
        commandsAsked[allowProbe, default: []].insert(key)
        // Counted now, not when the task starts: the `/` that asked must see
        // the loading row on this very update, or it closes for a frame.
        commandFetches[key, default: 0] += 1
        Task { [weak self] in await self?.runCommandFetch(key: key, allowProbe: allowProbe) }
    }

    /// The fetch itself; its caller has already counted it in `commandFetches`.
    private func runCommandFetch(key: String, allowProbe: Bool) async {
        let list = await fetchCommands?(allowProbe) ?? nil
        commandFetches[key, default: 1] -= 1
        if commandFetches[key] == 0 { commandFetches[key] = nil }
        if let list, !list.isEmpty { catalog.commands[key] = list }
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

    // MARK: - Text and caret

    /// Report the field's text and caret (UTF-16; nil for a ranged selection).
    func update(text: String, caretUTF16: Int?, focused: Bool) {
        if let closed = closedOnText, closed != text { closedOnText = nil }
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
        guard let found = ComposerTrigger.detect(text: text, caretUTF16: caret, agent: context().agent),
              case .command = found else { return nil }
        return found
    }

    private func setTrigger(_ next: ComposerTrigger?) {
        guard next != trigger else { return }
        trigger = next
        highlightedIndex = 0
        if case .command(let prefix, _, _)? = next {
            let ctx = context()
            if prefix == .slash, commands.isEmpty, !commandsLoading {
                startCommandFetch(key: catalogKey(ctx), allowProbe: true)
            }
            if ComposerInvocations.diskSkillTrigger(ctx.agent) == prefix { ensureSkills() }
        }
    }

    // MARK: - Panel

    /// What to draw above the field, or nil when nothing is open.
    var panel: ComposerPanelState? {
        switch trigger {
        case .command(let prefix, let query, _)?: return commandPanel(prefix: prefix, query: query)
        default: return nil
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

    // MARK: - Hardware keys

    /// A hardware key while the field has focus. `text` is the field's text
    /// right now.
    func handleKey(_ key: KeyEquivalent, shift: Bool, text: String) -> ComposerKeyOutcome {
        guard let panel else { return .ignored }
        if key == .escape {
            dismiss()
            return .handled
        }
        let rows = panel.rows
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
        guard let caret = lastCaret, case .command(_, _, let range)? = detect(lastText, caret: caret) else { return nil }
        let edit: ComposerEdit
        switch row {
        case .command(let command, _):
            edit = invocationEdit(ComposerInvocations.commandInvocationToken(command.name), replacing: range)
        case .skill(let skill, let prefix):
            edit = invocationEdit(prefix.rawValue + skill.id, replacing: range)
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

    /// The screen went away.
    func teardown() {
        setTrigger(nil)
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
