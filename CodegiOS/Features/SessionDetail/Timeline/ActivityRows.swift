import SwiftUI

// The activity timeline's tool rows (codeg 0.44 web parity: `activity-row.tsx`,
// `step-visuals.tsx`, `rows/*`). A row is one line — what the call did, what it
// acted on, a muted detail, and a figure on the right (`120 lines`, `3 hits`,
// `+3 −2`, `no matches`, `exit 1`) — that opens onto the call's body. Calls
// with lifecycles of their own (sub-agents, delegations, questions, plan mode,
// goals) keep their dedicated cards.

enum ActivityRowStyle {
    /// Whether this call draws as a plain activity row (else its own card).
    static func usesRow(_ step: ActivityToolStep) -> Bool {
        let vm = step.call
        guard vm.companion == nil, !vm.isPlanMode, vm.bucket != .task else { return false }
        switch step.tool.kind {
        case .read, .search, .glob, .list, .fetch, .webSearch, .memory,
             .command, .shellSession, .script, .monitor, .network,
             .edit, .mcp, .skill, .todo, .completion, .generic:
            return true
        default:
            return false
        }
    }

    /// The gutter icon for a call, by what it was (web `toolIcon`).
    static func icon(_ tool: ToolDescriptor) -> String {
        switch tool.kind {
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .glob: return "doc.text.magnifyingglass"
        case .list: return "folder"
        case .fetch, .webSearch: return "globe"
        case .memory: return "brain"
        case .command: return "apple.terminal"
        case .monitor: return "waveform.path.ecg"
        case .network: return "network.badge.shield.half.filled"
        case .shellSession: return tool.command?.session?.verb == .stdin ? "keyboard" : "timer"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .edit:
            let files = tool.files ?? []
            if files.count == 1, files[0].op == .delete { return "doc.badge.minus" }
            if !files.isEmpty, files.allSatisfy({ $0.op == .add || $0.op == .write }) { return "doc.badge.plus" }
            return "square.and.pencil"
        case .mcp: return "powerplug"
        case .skill: return "sparkles"
        case .todo: return "checklist"
        case .agent, .collabAgent: return "cpu"
        case .delegation, .delegationStatus, .delegationCancel, .delegationResume: return "person.2"
        case .goal: return "target"
        case .planMode: return "map"
        case .question: return "questionmark.bubble"
        case .feedback: return "bubble.left.and.bubble.right"
        case .workbench: return "list.clipboard"
        case .compaction: return "archivebox"
        case .completion: return "checkmark.circle"
        case .generic: return "wrench.and.screwdriver"
        }
    }

    /// The gutter marker's state for a status. A failure a later step redid
    /// reads settled, not red.
    static func markerState(_ status: StepStatus, recovered: Bool) -> ToolCallState {
        switch status {
        case .pending: return .inputStreaming
        case .running, .awaiting: return .running
        case .failed, .rejected: return recovered ? .done : .error
        case .succeeded, .cancelled: return .done
        }
    }
}

/// What a row says, split for styling.
struct ActivityRowLabel {
    var verb: String?
    var target: String?
    /// The target is code (a command line, a path) — set in monospace.
    var monoTarget = false
    var detail: String?
}

enum ActivityRowText {
    static func label(_ tool: ToolDescriptor) -> ActivityRowLabel {
        let target = tool.target?.text
        switch tool.kind {
        case .read:
            return .init(verb: String(localized: "Read"), target: target, monoTarget: true,
                         detail: joined(tool.detail, notes(tool.notes)))
        case .search:
            return .init(verb: String(localized: "Searched"), target: target, monoTarget: true, detail: tool.detail)
        case .glob:
            return .init(verb: String(localized: "Matched"), target: target, monoTarget: true, detail: tool.detail)
        case .list:
            return .init(verb: String(localized: "Listed"), target: target, monoTarget: true, detail: tool.detail)
        case .fetch:
            return .init(verb: String(localized: "Fetched"), target: target, detail: joined(tool.detail, notes(tool.notes)))
        case .webSearch:
            return .init(verb: String(localized: "Searched the web"), target: target, detail: tool.detail)
        case .memory:
            return .init(verb: String(localized: "Recalled"), target: target, detail: tool.detail)
        case .command, .monitor:
            let verb = tool.kind == .monitor ? String(localized: "Monitor") : nil
            guard let command = tool.command else {
                return .init(verb: verb ?? String(localized: "Command"), target: nil)
            }
            // The agent's own one-line description reads better than the
            // command it describes; the command is in the body.
            if let description = command.description {
                return .init(verb: verb, target: description,
                             detail: tool.background.map { backgroundText($0) })
            }
            if let heredoc = command.heredoc {
                let lines = String(localized: "\(heredoc.bodyLines)-line script", comment: "Activity row: a heredoc script")
                return .init(verb: verb ?? heredoc.interpreter, target: lines,
                             detail: tool.background.map { backgroundText($0) })
            }
            let first = command.display.components(separatedBy: "\n").first ?? ""
            let more = command.lineCount > 1
                ? String(localized: "+\(command.lineCount - 1) lines", comment: "Activity row: more command lines")
                : nil
            return .init(verb: verb, target: first.isEmpty ? String(localized: "Command") : first,
                         monoTarget: !first.isEmpty,
                         detail: joined(more, tool.background.map { backgroundText($0) }))
        case .network:
            return .init(verb: String(localized: "Network access"), target: target, monoTarget: true)
        case .shellSession:
            let session = tool.command?.session
            let verb: String
            switch session?.verb {
            case .terminate?: verb = String(localized: "Stop")
            case .stdin?: verb = String(localized: "Send keys")
            default: verb = String(localized: "Wait")
            }
            let id = session?.sessionId.map { String(localized: "session \($0)", comment: "Activity row: a shell session id") }
            let display = tool.command?.display
            return .init(verb: verb, target: display?.isEmpty == false ? display : id,
                         monoTarget: display?.isEmpty == false,
                         detail: display?.isEmpty == false ? id : nil)
        case .script:
            return .init(verb: String(localized: "Script"), target: tool.command?.display, monoTarget: true)
        case .edit:
            let files = tool.files ?? []
            if files.count > 1 {
                return .init(verb: String(localized: "Edited \(files.count) files", comment: "Activity row: a multi-file edit"))
            }
            let file = files.first
            let live = tool.status.isLive
            let verb: String
            switch file?.op {
            case .add?, .write?:
                verb = live ? String(localized: "Editing")
                    : String(localized: "activity.created", defaultValue: "Created", comment: "Edit row: a file the call created")
            case .delete?: verb = String(localized: "Deleted")
            case .move?: verb = String(localized: "Moved")
            default: verb = live ? String(localized: "Editing") : String(localized: "Edited")
            }
            let range = file?.lineRange.map { r in
                r.lowerBound == r.upperBound ? "L\(r.lowerBound)" : "L\(r.lowerBound)–\(r.upperBound)"
            }
            return .init(verb: verb, target: target ?? file.map { ActivityFormat.shortPath($0.path) },
                         monoTarget: true, detail: range)
        case .mcp:
            let server = tool.mcp?.server
            return .init(verb: server, target: target ?? tool.toolName, monoTarget: true, detail: tool.detail)
        case .skill:
            return .init(verb: String(localized: "Skill"), target: target)
        case .todo:
            if tool.toolName.lowercased() == "todowrite" {
                return .init(verb: String(localized: "Updated todos"), target: nil, detail: tool.detail)
            }
            return .init(verb: tool.toolName, target: target, detail: tool.detail)
        case .completion:
            return .init(verb: String(localized: "Completed"), target: target)
        default:
            return .init(verb: nil, target: target ?? tool.toolName, detail: tool.detail)
        }
    }

    static func backgroundText(_ background: ToolDescriptor.Background) -> String {
        if let id = background.taskId { return String(localized: "background · #\(id)", comment: "Activity row: a backgrounded command's task id") }
        return String(localized: "background")
    }

    static func notes(_ notes: [ToolNote]) -> String? {
        let parts = notes.map { note -> String in
            switch note {
            case .allowLarge: return String(localized: "past the size limit")
            case .pages(let pages): return String(localized: "pages \(pages)", comment: "Activity row: PDF pages read")
            case .offset(let offset): return String(localized: "from \(offset)", comment: "Activity row: fetch offset")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func joined(_ parts: String?...) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    /// The word an exit means (web `EXIT_WORD`).
    static func exitWord(_ meaning: ExitMeaning) -> String {
        switch meaning {
        case .noMatch: return String(localized: "no matches")
        case .false: return String(localized: "false")
        case .differs: return String(localized: "differs")
        case .notFound: return String(localized: "not found")
        case .commandNotFound: return String(localized: "command not found")
        case .notExecutable: return String(localized: "not executable")
        case .timedOut: return String(localized: "timed out")
        }
    }
}

/// The figure on a row's right (web `ToolFigure`): the failure word for a call
/// that did not succeed, what an answering exit means, or the call's metric.
struct ActivityFigure: View {
    let tool: ToolDescriptor
    var recovered = false

    var body: some View {
        switch tool.status {
        case .failed:
            let word = tool.exitMeaning.map(ActivityRowText.exitWord)
                ?? tool.exit?.signal.map { String(localized: "killed · \($0)", comment: "Activity row: killed by a signal") }
                ?? tool.exit?.code.map { String(localized: "exit \($0)", comment: "Activity row: exit code") }
                ?? String(localized: "failed")
            figure(recovered ? word + " · " + String(localized: "recovered") : word,
                   recovered ? Theme.textTertiary : Theme.danger)
        case .rejected:
            figure(String(localized: "declined"), Theme.danger)
        case .cancelled:
            figure(String(localized: "interrupted"), Theme.textTertiary)
        case .awaiting:
            figure(String(localized: "needs you"), Theme.warning)
        case .running, .pending:
            ProgressView().controlSize(.mini)
        case .succeeded:
            if let meaning = tool.exitMeaning {
                figure(ActivityRowText.exitWord(meaning), Theme.textTertiary)
            } else if let metric = tool.metric {
                metricView(metric)
            }
        }
    }

    @ViewBuilder
    private func metricView(_ metric: ToolMetric) -> some View {
        switch metric {
        case .lines(let n): figure(String(localized: "\(n) lines", comment: "Activity row: lines read"), Theme.textTertiary)
        case .matches(let n, _): figure(String(localized: "\(n) hits", comment: "Activity row: search hits"), Theme.textTertiary)
        case .files(let n): figure(String(localized: "\(n) files", comment: "Activity row: files matched"), Theme.textTertiary)
        case .results(let n): figure(String(localized: "\(n) results", comment: "Activity row: search results"), Theme.textTertiary)
        case .noMatch: figure(String(localized: "no matches"), Theme.textTertiary)
        case .diff(let adds, let dels):
            HStack(spacing: 5) {
                if adds > 0 { Text(verbatim: "+\(adds)").foregroundStyle(DiffPalette.addText) }
                if dels > 0 { Text(verbatim: "−\(dels)").foregroundStyle(DiffPalette.delText) }
            }
            .font(Theme.Typography.microLabel.monospacedDigit())
        }
    }

    private func figure(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// One tool call as an activity row.
struct ActivityToolRow: View {
    let step: ActivityToolStep
    var recovered = false
    /// Drawn inside a group's panel: no separate surface.
    var nested = false

    @State private var userExpanded: Bool?

    private var vm: ToolCallVM { step.call }
    private var tool: ToolDescriptor { step.tool }

    /// Opens by itself while it needs attention: running (live output), a
    /// failure nothing redid, or waiting on the user.
    private var autoExpands: Bool {
        switch tool.status {
        case .running, .awaiting: return tool.kind == .command || tool.kind == .shellSession || tool.status == .awaiting
        case .failed, .rejected: return !recovered
        default: return false
        }
    }
    private var expanded: Bool { userExpanded ?? autoExpands }
    private var hasBody: Bool {
        vm.diffFiles != nil || vm.hasOutput
            || (vm.input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    /// A backgrounded command's (or a monitor's) result is the CLI's note to
    /// the model that the work goes on in the background; the reader gets
    /// which task it is instead (web `useCommandOutput`).
    private var backgroundNote: String? {
        guard let id = tool.background?.taskId, !vm.isError,
              let output = vm.output, !output.isEmpty else { return nil }
        return tool.kind == .monitor
            ? String(localized: "Watching in background · \(id)", comment: "Activity row: a monitor's output, kept in the background under this task id")
            : String(localized: "Running in background · \(id)", comment: "Activity row: a backgrounded command's output, under this task id")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded, hasBody {
                ToolCallBody(vm: vm, showsTranscript: false, outputNote: backgroundNote)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        let label = ActivityRowText.label(tool)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let verb = label.verb {
                    Text(verbatim: verb)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                }
                if let target = label.target {
                    Text(verbatim: target)
                        .font(label.monoTarget ? .mono(13) : .subheadline)
                        .foregroundStyle(label.verb == nil ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
                if let detail = label.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            ActivityFigure(tool: tool, recovered: recovered)
            if hasBody {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.vertical, nested ? 4 : 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            withAnimation(Theme.Motion.expand) { userExpanded = !expanded }
        }
    }
}

/// A folded run of explore / command calls (web `ExploreGroupRow` /
/// `CommandGroupRow`): `Explored 2 files, 1 search` / `Ran 3 commands`, opening
/// onto the member rows.
struct ActivityGroupRow: View {
    let kind: ActivityGroupKind
    let steps: [ActivityToolStep]
    let status: StepStatus
    let recoveredKeys: Set<String>

    @State private var userExpanded: Bool?

    private var unrecoveredFailures: Int {
        steps.filter { $0.tool.status.isFailure && !recoveredKeys.contains($0.key) }.count
    }
    /// Open while a member runs (a command's live output) or a failure stands.
    private var autoExpands: Bool {
        (kind == .command && status.isLive) || unrecoveredFailures > 0 || status == .awaiting
    }
    private var expanded: Bool { userExpanded ?? autoExpands }

    private var title: String {
        let live = status.isLive
        switch kind {
        case .command:
            return live
                ? String(localized: "Running \(steps.count) commands", comment: "Activity group: commands running")
                : String(localized: "Ran \(steps.count) commands", comment: "Activity group: commands run")
        case .explore:
            return live ? String(localized: "Exploring") : String(localized: "Explored")
        }
    }

    /// `2 files, 1 search` — what an explore run covered.
    private var exploreSummary: String? {
        guard kind == .explore else { return nil }
        var files = Set<String>()
        var searches = 0, listings = 0, pages = 0, webSearches = 0, memories = 0
        for step in steps {
            switch step.tool.kind {
            case .read: files.insert(step.tool.target?.path ?? step.tool.target?.text ?? step.key)
            case .search, .glob: searches += 1
            case .list: listings += 1
            case .fetch: pages += 1
            case .webSearch: webSearches += 1
            case .memory: memories += 1
            default: break
            }
        }
        var parts: [String] = []
        if !files.isEmpty { parts.append(String(localized: "\(files.count) files", comment: "Explore group: files read")) }
        if searches > 0 { parts.append(String(localized: "\(searches) searches", comment: "Explore group: searches")) }
        if listings > 0 { parts.append(String(localized: "\(listings) listings", comment: "Explore group: listings")) }
        if pages > 0 { parts.append(String(localized: "\(pages) pages", comment: "Explore group: pages fetched")) }
        if webSearches > 0 { parts.append(String(localized: "\(webSearches) web searches", comment: "Explore group: web searches")) }
        if memories > 0 { parts.append(String(localized: "\(memories) memory lookups", comment: "Explore group: memory lookups")) }
        return parts.isEmpty ? nil : parts.joined(separator: String(localized: ", ", comment: "List joiner"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                if let summary = exploreSummary {
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if status.isLive {
                    ProgressView().controlSize(.mini)
                } else if unrecoveredFailures > 0 {
                    Text(verbatim: String(localized: "\(unrecoveredFailures) failed", comment: "Activity header: unrecovered failures"))
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Theme.Motion.expand) { userExpanded = !expanded } }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps, id: \.key) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: ActivityRowStyle.icon(step.tool))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 16)
                            ActivityToolRow(step: step, recovered: recoveredKeys.contains(step.key), nested: true)
                        }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
    }
}
