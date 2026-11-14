import SwiftUI

/// The content to the right of a timeline node's marker. Dispatches on the node's
/// `Content` and reuses the existing rendering leaves verbatim — `MarkdownContent`,
/// `ToolCallCard`, `DiffView`, `ReasoningBlock`, `InlineImageView`,
/// `LivePlanView` — so the timeline is purely a new *shell*: the per-block
/// renderers (and their caches) are unchanged. Live text / reasoning are rendered
/// by small `@Bindable` leaves that read `run.text`, preserving the 50 ms-coalesced
/// streaming + caret behaviour.
struct NodeBody: View {
    let node: TimelineNode

    var body: some View {
        switch node.content {
        case .user(let turn):
            UserNodeBody(turn: turn)
        case .system(let turn):
            SystemNodeBody(turn: turn)
        case .assistantText(let s):
            MarkdownContent(raw: s, assistantReply: true)
        case .liveText(let run, let streaming):
            LiveTextNode(run: run, streaming: streaming)
        case .proposedPlan(let markdown, let streaming):
            ProposedPlanCard(markdown: markdown, streaming: streaming)
        case .reasoning(let t):
            ReasoningBlock(text: t)
        case .liveReasoning(let run, let streaming):
            LiveReasoningNode(run: run, streaming: streaming)
        case .tool(let vm):
            switch vm.companion {
            case .delegate:
                DelegatedSubThreadCard(vm: vm)
            case .cancelDelegation:
                DelegationStatusGroupCard(polls: [vm], kind: .cancel)
            case .delegationStatus:
                // Normally grouped upstream; a lone straggler still renders as a card.
                DelegationStatusGroupCard(polls: [vm], kind: .status)
            case .askQuestion:
                AskQuestionResultCard(vm: vm)
            case .none:
                // A refused resume revived nothing: the broker's reason is the card.
                if let refusal = DelegationModel.resumeRefusal(vm) {
                    RefusedResumeCard(vm: vm, refusal: refusal)
                } else {
                    ToolCallCard(vm: vm)
                }
            }
        case .delegationStatusGroup(let polls):
            DelegationStatusGroupCard(polls: polls)
        case .taskGroup(let ops):
            TaskListCard(ops: ops)
        case .image(let img, let cap):
            InlineImageView(image: img, caption: cap)
                .railHead(.top(14))
        case .compaction(let before, let after, let running):
            ContextCompactionDivider(before: before, after: after, running: running)
        case .footer(let turn, let questionID):
            TurnFooter(turn: turn, questionID: questionID, forkPoint: node.forkPoint)
        case .plan(let entries, let streaming):
            LivePlanView(entries: entries, isStreaming: streaming)
        case .thinking:
            ThinkingShimmer()
                .railHead(.top(10))
        case .error(let message, let details):
            InlineTurnError(message: message, details: details)
        case .unsupported(let type):
            UnsupportedBlock(type: type)
        case .replyHeader(let header):
            ReplyHeaderView(header: header, open: node.foldOpen, currentRound: node.currentRound)
        case .replyFoot(let header):
            ReplyFootView(header: header, currentRound: node.currentRound)
        case .thought(let text, let streaming):
            ThoughtNodeBody(text: text, streaming: streaming)
        case .activityGroup(let kind, let steps, let status, let recovered):
            ActivityGroupRow(kind: kind, steps: steps, status: status, recoveredKeys: recovered)
        case .activityTool(let step, let recovered):
            ActivityToolRow(step: step, recovered: recovered)
        case .goal(let goal):
            GoalRunRow(goal: goal, agent: node.agent)
        case .backgroundTask(let row, let launch):
            BackgroundTaskRowView(row: row, launch: launch)
        }
    }
}

// MARK: - User

/// The user's own message, as a left-aligned faint-accent card (the timeline puts
/// every actor on one spine, so user prompts are rail nodes too — not right-side
/// bubbles). The card fills the content column to the same width as the agent's
/// message cards, so a user turn and the reply it prompts read as one column.
private struct UserNodeBody: View {
    let turn: MessageTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(raw: text)
                        .multilineTextAlignment(.leading)
                case .image(let image):
                    InlineImageView(image: image, caption: nil)
                default:
                    ContentBlockView(block: block)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.accent.opacity(0.14),
            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        )
        .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.30))
    }
}

// MARK: - System

/// A system note as a left-aligned dim line (log-style), so it reads as a minor
/// tick on the rail rather than a centered banner. The builder skips empty system
/// turns, so this always has text.
private struct SystemNodeBody: View {
    let turn: MessageTurn

    var body: some View {
        Text(SystemText.of(turn))
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Joins a turn's text blocks — shared by the builder (to skip empty system turns)
/// and the system body.
enum SystemText {
    static func of(_ turn: MessageTurn) -> String {
        turn.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Live text / reasoning leaves

/// Streaming prose. Holds the `LiveTextRun` as `@Bindable` and reads `run.text`
/// in its own body so each ~50 ms coalesced publish re-renders just this node
/// (and only the trailing segment carries the typing caret). The text MUST be
/// read here, not snapshotted into the node, or streaming stops updating.
///
/// A codex Plan-mode `<proposed_plan>` block is lifted out HERE for a live
/// run, not by the timeline builder: reading the run's text while assembling
/// the timeline would subscribe the whole transcript to every token. Plan and
/// prose are both answer-shaped (`BuildActivity.isAnswerPart`), so splitting
/// the run inside its own node changes nothing about where the run sits in the
/// reply. Once the reply settles, the persisted adapter makes the same split
/// into nodes of their own.
private struct LiveTextNode: View {
    @Bindable var run: LiveTextRun
    let streaming: Bool

    var body: some View {
        let text = run.text
        if let segments = ProposedPlan.extract(text, isStreaming: streaming) {
            ProposedPlanSegmentsView(segments: segments, streaming: streaming)
        } else {
            MarkdownContent(raw: text, streaming: streaming, assistantReply: true)
        }
    }
}

private struct LiveReasoningNode: View {
    @Bindable var run: LiveTextRun
    let streaming: Bool

    var body: some View {
        ReasoningBlock(text: run.text, streaming: streaming)
    }
}

// MARK: - Footer (migrated from the old TurnView)

/// The action + metadata row under an assistant reply: a leading Copy affordance,
/// a "scroll to question" jump, then the reply time and faint model / token /
/// duration stats. The copy button is omitted only when the turn has no prose to
/// copy; the jump only when there's a known prompting user message.
private struct TurnFooter: View {
    @Environment(\.locale) private var locale
    let turn: MessageTurn
    var questionID: String?
    /// Where "Fork from here" forks; the button itself decides whether to show.
    var forkPoint: ReplyForkPoint?

    private var copyText: String {
        turn.blocks.compactMap { block -> String? in
            guard case .text(let t) = block,
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return t
        }.joined(separator: "\n\n")
    }

    private var metaText: String {
        var parts: [String] = [RelativeTime.string(from: turn.completedAt ?? turn.timestamp, locale: locale)]
        if let usage = turn.usage, usage.total > 0 { parts.append(TokenFormat.compact(usage.total)) }
        if let ms = turn.durationMs, ms > 0 { parts.append(DurationFormat.short(ms)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            if !copyText.isEmpty {
                CopyButton(text: copyText, label: "Copy")
            }
            if let questionID {
                JumpToQuestionButton(questionID: questionID)
            }
            if let forkPoint {
                ForkReplyButton(point: forkPoint)
            }
            Spacer(minLength: 8)
            if let model = turn.model, !model.isEmpty {
                Text(model)
                    .font(Theme.Typography.codeMeta)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Text(metaText)
                .font(Theme.Typography.metaLabel.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
        .padding(.top, 2)
    }
}

/// "Scroll to the question" — jumps the viewport up to the user message that
/// prompted this reply, via the transcript's published scroll action.
private struct JumpToQuestionButton: View {
    let questionID: String
    @Environment(\.transcriptScroll) private var scroll

    var body: some View {
        Button {
            scroll(questionID, anchor: .top)
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to question")
    }
}

// MARK: - Live affordances (migrated from the old LiveTurnView)

/// A subtle three-dot shimmer shown before the first token lands. Static under
/// Reduce Motion.
struct ThinkingShimmer: View {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 0.6 : (phase ? 1 : 0.3))
                    .animation(
                        reduceMotion ? nil :
                            .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18),
                        value: phase
                    )
            }
        }
        .padding(.vertical, 4)
        .onAppear { if !reduceMotion { phase = true } }
    }
}

/// Inline error banner shown at the tail of a turn that errored or was cancelled.
/// The context-compaction boundary: a hairline running the content width with a
/// small archive glyph + label centered on it. Deliberately chrome-less (no card,
/// no border) — it marks "the conversation's context was compacted here", it is
/// not something the agent *did*.
///
/// Grok stamps the before/after token counts on its compaction; codex sends none,
/// and a no-op delta (before == after) would read as a bug, so both fall back to
/// the plain label.
struct ContextCompactionDivider: View {
    let before: Int?
    let after: Int?
    let running: Bool

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func format(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private var label: Text {
        if running { return Text("Compacting context…") }
        if let before, let after, before != after {
            return Text("Context compacted · \(format(before)) → \(format(after)) tokens")
        }
        return Text("Context compacted")
    }

    var body: some View {
        HStack(spacing: 10) {
            hairline
            HStack(spacing: 5) {
                Image(systemName: "archivebox")
                    .font(.system(size: 11, weight: .medium))
                label
                    .font(Theme.Typography.metaLabel)
            }
            .foregroundStyle(Theme.textTertiary)
            .opacity(running ? 0.65 : 1)
            .fixedSize()
            hairline
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

struct InlineTurnError: View {
    let message: String
    /// Server-supplied diagnostic evidence (agent stderr tail, unparsed-update
    /// counts). Kept behind a disclosure and out of the one-line message: it is
    /// multi-line raw agent output, and only useful once the user asks why.
    var details: String?

    @State private var detailsExpanded = false

    /// Guard against a pathological stderr tail. The server already bounds this,
    /// but the bound is its own, not one this card's layout agreed to.
    private static let maxDetailChars = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details, !details.isEmpty {
                disclosure(details)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.danger.opacity(0.4))
    }

    @ViewBuilder
    private func disclosure(_ details: String) -> some View {
        Button {
            withAnimation(Theme.Motion.expand) { detailsExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Details")
                    .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
            }
            .foregroundStyle(Theme.danger.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if detailsExpanded {
            ScrollView(.horizontal, showsIndicators: false) {
                // Selectable on purpose. The server's containment rule is that
                // this payload must not be *forwarded automatically* to anything
                // that outlives the app — an OS notification, a status tooltip —
                // and it is redacted at the source precisely so it can be shown.
                // Letting the user copy a stack trace into a bug report is the
                // reason it is here at all; the web alert is likewise selectable.
                Text(verbatim: String(details.prefix(Self.maxDetailChars)))
                    .font(Theme.Typography.diffCode)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .transition(.opacity)
        }
    }
}
