import SwiftUI

// This file owns the tool-call cards (`ToolCallCard` / `ToolGroupCard`) and their
// per-tool input/output bodies. The transcript timeline renders these directly as
// node bodies (`NodeBody`); the streaming text/reasoning leaves and the old
// `RenderPartsView` aggregator moved to `Timeline/TimelineNodeBody.swift`.

// MARK: - Tool group

/// A collapsed summary of a run of consecutive tool calls
/// ("Read 3 files · Edited 2 files"), expanding to the individual cards.
struct ToolGroupCard: View {
    let items: [ToolCallVM]
    let streaming: Bool
    @State private var expanded = false

    private var errorCount: Int { items.filter(\.isError).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { ToolCallCard(vm: $0, nested: true) }
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.Motion.expand) { expanded.toggle() } }
    }

    private var header: some View {
        // The gutter marker carries the stacked-tools icon for this group node;
        // the card header shows just the summary + state, no duplicate icon.
        HStack(spacing: 8) {
            Text(ToolGroupSummary.text(items))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
            if streaming {
                LivePulse()
            } else if errorCount > 0 {
                Text("\(errorCount) failed")
                    .font(Theme.Typography.microLabel)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.danger.opacity(0.16), in: Capsule())
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
    }
}

/// Builds the "Read 3 files · Edited 2 files" summary for a tool group.
enum ToolGroupSummary {
    static func text(_ items: [ToolCallVM]) -> String {
        var counts: [ToolKindBucket: Int] = [:]
        for it in items { counts[it.bucket, default: 0] += 1 }
        let order: [ToolKindBucket] = [.read, .edit, .search, .execute, .web, .todo, .task, .taskMgmt, .other]
        let phrases = order.compactMap { b -> String? in
            guard let c = counts[b], c > 0 else { return nil }
            return phrase(b, c)
        }
        return phrases.isEmpty ? "\(items.count) tools" : phrases.joined(separator: " · ")
    }

    private static func phrase(_ b: ToolKindBucket, _ c: Int) -> String {
        let s = c > 1
        switch b {
        case .read: return "Read \(c) file\(s ? "s" : "")"
        case .edit: return "Edited \(c) file\(s ? "s" : "")"
        case .search: return "\(c) search\(s ? "es" : "")"
        case .execute: return "Ran \(c) command\(s ? "s" : "")"
        case .web: return "\(c) web request\(s ? "s" : "")"
        case .todo: return "Updated todos"
        case .task: return "\(c) task\(s ? "s" : "")"
        // Task-management calls never enter a generic group (they form their own
        // `taskGroup`); this keeps the switch exhaustive.
        case .taskMgmt: return "\(c) task update\(s ? "s" : "")"
        case .other: return "\(c) tool\(s ? "s" : "")"
        }
    }
}

// MARK: - Single tool card

/// One tool call: a header (icon, derived title, status, +adds/−dels) over a
/// collapsible body (a diff, a per-tool input view, and/or output). Collapsed by
/// default; auto-opens while running or on error so live output and failures are
/// visible without a tap.
struct ToolCallCard: View {
    let vm: ToolCallVM
    var nested: Bool = false

    @State private var userExpanded: Bool?

    /// Auto-open while running / on error (so live output and failures are
    /// visible without a tap), and for a small diff (the change is the point on
    /// mobile). Large diffs stay collapsed behind their +N/−M stat.
    private var autoExpands: Bool {
        if vm.state == .running || vm.state == .error { return true }
        if let files = vm.diffFiles {
            let rows = files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.rows.count } }
            return rows <= 40
        }
        return false
    }
    private var isExpanded: Bool { userExpanded ?? autoExpands }
    private var hasInput: Bool { (vm.input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    /// The sub-agent transcript is live-only and disappears once the result
    /// lands, so it is shown only while the call is actually running — matching
    /// the web, and avoiding a section that would blink out at settle.
    private var showsTranscript: Bool {
        !vm.transcript.isEmpty && (vm.state == .running || vm.state == .inputStreaming)
    }
    private var hasBody: Bool { vm.diffFiles != nil || vm.hasOutput || hasInput || showsTranscript }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded, hasBody { bodyContent }
        }
        .padding(12)
        .modifier(CardSurface(nested: nested))
    }

    private var header: some View {
        // No leading tool icon here: the timeline gutter marker already shows it
        // (and tints it by state), so repeating it in the card is redundant.
        HStack(spacing: 8) {
            Text(LocalizedStringKey(stringLiteral: vm.displayTitle))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
            ToolStateIndicator(state: vm.state)
            Spacer(minLength: 4)
            diffStat
            if hasBody {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            withAnimation(Theme.Motion.expand) { userExpanded = !isExpanded }
        }
    }

    @ViewBuilder
    private var diffStat: some View {
        if let files = vm.diffFiles {
            let adds = files.reduce(0) { $0 + $1.additions }
            let dels = files.reduce(0) { $0 + $1.deletions }
            HStack(spacing: 6) {
                if adds > 0 { Text("+\(adds)").font(Theme.Typography.microLabel.monospacedDigit()).foregroundStyle(DiffPalette.addText) }
                if dels > 0 { Text("−\(dels)").font(Theme.Typography.microLabel.monospacedDigit()).foregroundStyle(DiffPalette.delText) }
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let files = vm.diffFiles {
            DiffView(files: files)
        } else {
            inputBody
            if showsTranscript { SubAgentTranscript(runs: vm.transcript) }
            outputBody
        }
    }

    /// A successful Read shows its file body line-numbered (the codeg server
    /// returns `{start_line, content}`); every other output uses the generic
    /// renderer, which classifies JSON / diff / Markdown / log.
    @ViewBuilder
    private var outputBody: some View {
        if vm.bucket == .read, !vm.isError, let file = ReadOutputFormat.parse(vm.trimmedOutput) {
            FileBodyView(file: file)
        } else if vm.hasOutput {
            ToolOutputBody(output: vm.trimmedOutput, isError: vm.isError, isCommand: vm.isCommand)
        }
    }

    @ViewBuilder
    private var inputBody: some View {
        switch vm.bucket {
        case .execute: BashInputBody(vm: vm)
        case .read: FileInputBody(vm: vm)
        case .search: SearchInputBody(vm: vm)
        case .todo: TodoInputBody(vm: vm)
        case .web: WebInputBody(vm: vm)
        default: GenericInputBody(vm: vm)
        }
    }
}

/// The live transcript of a sub-agent launched by this tool call — the
/// sub-agent's own prose and reasoning, which the wire interleaves with the main
/// thread's and which used to be spliced straight into the reply the user was
/// reading. See ``SubAgentRun``.
///
/// The RENDER is tail-bounded (the data is not): a sub-agent narrating its way
/// through a long task produces an unbounded transcript, and only the recent
/// tail is informative while it works. Mirrors the web's
/// `AGENT_TRANSCRIPT_RENDER_TAIL`.
private struct SubAgentTranscript: View {
    let runs: [SubAgentRun]

    private static let renderTail = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Same wording as the web's `agentLiveTranscript`.
            Text("Live activity")
                .font(Theme.Typography.microLabel)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            ForEach(runs.suffix(Self.renderTail)) { entry in
                SubAgentRunRow(run: entry.run, isThinking: entry.isThinking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One transcript run. Holds its `LiveTextRun` as `@Bindable` and reads
/// `run.text` in its OWN body, so each coalesced publish re-renders just this
/// row instead of the whole card (the same rule `LiveTextNode` follows).
private struct SubAgentRunRow: View {
    @Bindable var run: LiveTextRun
    let isThinking: Bool

    /// Characters of one run actually drawn. A sub-agent can stream indefinitely
    /// into a single run, and every ~50–140 ms coalesce re-parses and re-lays-out
    /// whatever it holds — unbounded main-thread work for scaffolding the user is
    /// skimming, not reading. Capping the tail bounds the parse, the
    /// `AttributedString`, and the text layout; the run's own data is untouched.
    private static let renderTailChars = 2_000

    /// The tail, with a leading ellipsis once anything was dropped. The length
    /// probe is on `utf8` (O(1) on a native string) so the common under-cap case
    /// pays nothing; the slice itself only runs when the cap is exceeded.
    private var visibleText: String {
        let text = run.text
        guard text.utf8.count > Self.renderTailChars else { return text }
        return "…" + String(text.suffix(Self.renderTailChars))
    }

    var body: some View {
        if isThinking {
            // Reasoning renders verbatim (as the web does). An empty run is the
            // "reasoning started" placeholder — the card's own spinner already
            // says that, so there is nothing to draw.
            if !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: visibleText)
                    .font(Theme.Typography.metaLabel.italic())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Parsed inline but deliberately NOT through `MarkdownText`: every
            // delta is a distinct string, so its LRU would churn its whole
            // capacity on one chatty sub-agent. Code spans and emphasis read
            // properly this way, which raw backticks do not.
            Text(MarkdownText.attributed(from: visibleText))
                .font(.callout)
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A flat tinted surface for a top-level card; a fainter inset when nested
/// inside a group. Shadowless by design (no Liquid Glass) so grouped tool
/// components read as calm boxes rather than floating cards.
private struct CardSurface: ViewModifier {
    let nested: Bool
    func body(content: Content) -> some View {
        if nested {
            content
                .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
        } else {
            content
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md)
        }
    }
}

private struct ToolStateIndicator: View {
    let state: ToolCallState

    var body: some View {
        switch state {
        case .running, .inputStreaming:
            LivePulse()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiffPalette.addText.opacity(0.85))
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.danger)
        }
    }
}

// MARK: - Per-tool input bodies

private struct BashInputBody: View {
    let vm: ToolCallVM
    var body: some View {
        let parsed = ToolDerive.parseJSON(vm.input)
        let args = ToolDerive.effectiveArgs(parsed)
        VStack(alignment: .leading, spacing: 6) {
            if let cmd = ToolDerive.extractCommand(input: vm.input, parsed: parsed) {
                // Handles a JSON `command` field AND a bare command string (Codex
                // `exec_command` persists the raw command, not JSON).
                CodeBlockView(code: cmd, language: "bash")
            } else if let input = vm.input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // No command anywhere (e.g. a tool the ACP kind labeled "execute"
                // but whose args are structured) — show fields, not raw JSON.
                StructuredJSONView(json: input)
            }
            let chips = bashChips(args)
            if !chips.isEmpty {
                HStack(spacing: 6) { ForEach(chips, id: \.self) { MetaBadge(text: $0) } }
            }
        }
    }
    private func bashChips(_ args: [String: Any]?) -> [String] {
        var out: [String] = []
        if (args?["background"] as? Bool) == true || (args?["run_in_background"] as? Bool) == true { out.append("background") }
        if let t = args?["timeout"] { out.append("timeout \(t)") }
        if let cwd = strArg(args, ["cwd", "working_dir", "workdir"]) { out.append(PathFormat.short(cwd)) }
        return out
    }
}

private struct FileInputBody: View {
    let vm: ToolCallVM
    var body: some View {
        let args = ToolDerive.effectiveArgs(ToolDerive.parseJSON(vm.input))
        VStack(alignment: .leading, spacing: 6) {
            if let path = strArg(args, ["file_path", "path", "filename", "file", "target_file"]) {
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    Text(path)
                        .font(.mono(11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            let chips = fileChips(args)
            if !chips.isEmpty {
                HStack(spacing: 6) { ForEach(chips, id: \.self) { MetaBadge(text: $0) } }
            }
            if let content = strArg(args, ["content", "file_text", "new_source"]), !content.isEmpty {
                CodeBlockView(code: content, language: nil)
            }
        }
    }
    private func fileChips(_ args: [String: Any]?) -> [String] {
        var out: [String] = []
        if let o = args?["offset"] { out.append("offset \(o)") }
        if let l = args?["limit"] { out.append("limit \(l)") }
        if let p = args?["pages"] { out.append("pages \(p)") }
        return out
    }
}

private struct SearchInputBody: View {
    let vm: ToolCallVM
    var body: some View {
        let args = ToolDerive.effectiveArgs(ToolDerive.parseJSON(vm.input))
        VStack(alignment: .leading, spacing: 6) {
            if let pat = strArg(args, ["pattern", "query", "regex", "q", "glob"]) {
                Text(pat)
                    .font(.mono(11.5)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .textSelection(.enabled)
            }
            let chips = searchChips(args)
            if !chips.isEmpty {
                HStack(spacing: 6) { ForEach(chips, id: \.self) { MetaBadge(text: $0) } }
            }
        }
    }
    private func searchChips(_ args: [String: Any]?) -> [String] {
        var out: [String] = []
        if let p = strArg(args, ["path", "dir"]) { out.append(PathFormat.short(p)) }
        if let g = strArg(args, ["glob", "include", "type"]) { out.append(g) }
        if let m = strArg(args, ["output_mode"]) { out.append(m) }
        if (args?["-i"] as? Bool) == true || (args?["case_insensitive"] as? Bool) == true { out.append("case-insensitive") }
        return out
    }
}

private struct TodoInputBody: View {
    let vm: ToolCallVM
    var body: some View {
        let args = ToolDerive.effectiveArgs(ToolDerive.parseJSON(vm.input))
        let todos = (args?["todos"] as? [[String: Any]]) ?? (args?["todoList"] as? [[String: Any]]) ?? []
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = (todo["status"] as? String) ?? "pending"
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: todoIcon(status))
                        .font(.system(size: 11))
                        .foregroundStyle(todoTint(status))
                    Text((todo["content"] as? String) ?? (todo["title"] as? String) ?? "")
                        .font(.caption)
                        .foregroundStyle(status == "completed" ? Theme.textTertiary : Theme.textSecondary)
                        .strikethrough(status == "completed")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func todoIcon(_ s: String) -> String {
        switch s {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted.circle"
        default: return "circle"
        }
    }
    private func todoTint(_ s: String) -> Color {
        switch s {
        case "completed": return DiffPalette.addText
        case "in_progress": return Theme.accent
        default: return Theme.textTertiary
        }
    }
}

private struct WebInputBody: View {
    let vm: ToolCallVM
    var body: some View {
        let args = ToolDerive.effectiveArgs(ToolDerive.parseJSON(vm.input))
        VStack(alignment: .leading, spacing: 6) {
            if let url = strArg(args, ["url"]) {
                pill(icon: "globe", text: url)
            } else if let q = strArg(args, ["query", "q"]) {
                pill(icon: "magnifyingglass", text: q)
            }
            if let prompt = strArg(args, ["prompt"]), !prompt.isEmpty {
                MarkdownContent(raw: prompt)
            }
        }
    }
    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            Text(text).font(.mono(11)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// Any tool we don't render with a dedicated body — most MCP calls land here.
/// Renders the argument JSON as a structured field list (label + value) instead
/// of a dumped raw-JSON string. Mirrors web `GenericToolInput`.
private struct GenericInputBody: View {
    let vm: ToolCallVM
    var body: some View {
        if let input = vm.input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            StructuredJSONView(json: input)
        }
    }
}

// MARK: - Output

private struct ToolOutputBody: View {
    let output: String
    let isError: Bool
    let isCommand: Bool

    var body: some View {
        if isError {
            ToolErrorOutput(output: output)
        } else if isCommand {
            // Unwrap JSON command envelopes + strip CLI metadata so a shell
            // result reads as a terminal, not a raw `{stdout,exit_code,…}` blob.
            let clean = ToolOutputFormat.cleanCommandOutput(output)
            if !clean.isEmpty { CodeBlockView(code: clean, language: "console") }
        } else {
            switch ToolOutputFormat.classify(output) {
            case .json:
                CodeBlockView(code: ToolJSONFormat.prettyPrintString(output) ?? output, language: "json")
            case .diff:
                if UnifiedDiff.looksLikeDiff(output), let files = UnifiedDiff.parse(output) {
                    DiffView(files: files)
                } else {
                    CodeBlockView(code: output, language: "diff")
                }
            case .markdown:
                MarkdownContent(raw: output)
            case .log:
                CodeBlockView(code: output, language: "output")
            }
        }
    }
}

/// Error output. A JSON-object error body is split into labeled fields (so an
/// `{error, code, detail}` envelope is readable); plain text falls back to a
/// mono block. Mirrors web `renderErrorText`.
private struct ToolErrorOutput: View {
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 10, weight: .semibold))
                Text("Error output").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.danger)

            if let fields = ToolOutputFormat.errorFields(output) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.0.uppercased())
                            .font(Theme.Typography.microLabel)
                            .tracking(0.6)
                            .foregroundStyle(Theme.danger.opacity(0.7))
                        errorText(field.1)
                    }
                }
            } else {
                errorText(output)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.danger.opacity(0.4))
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.mono(11.5)).foregroundStyle(Theme.danger.opacity(0.92))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Small helpers

private struct MetaBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Typography.metaLabel)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private func strArg(_ args: [String: Any]?, _ keys: [String]) -> String? {
    for k in keys { if let v = args?[k] as? String, !v.isEmpty { return v } }
    return nil
}

