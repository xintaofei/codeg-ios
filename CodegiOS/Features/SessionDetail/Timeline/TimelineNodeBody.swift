import SwiftUI

/// The content to the right of a timeline node's marker. Dispatches on the node's
/// `Content` and reuses the existing rendering leaves verbatim — `MarkdownContent`,
/// `ToolCallCard`, `DiffView`, `ReasoningBlock`, `InlineImageView`,
/// `LivePlanView` — so the timeline is purely a new *shell*: the per-block
/// renderers (and their caches) are unchanged. Live text / reasoning are rendered
/// by small `@Bindable` leaves that read `run.text`, preserving the 50 ms-coalesced
/// streaming + caret behaviour.
///
/// Every disclosure inside remembers what the reader opened under this node's
/// id (``DisclosureStore``), so a row the list recycles comes back as it was
/// left.
struct NodeBody: View {
    let node: TimelineNode

    var body: some View {
        content.disclosureRoot(node.id)
    }

    @ViewBuilder
    private var content: some View {
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
                DelegationTaskCard(vm: vm)
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
        case .delegation(let vm, let later):
            DelegationTaskCard(vm: vm, later: later)
        case .delegationStatusGroup(let polls):
            DelegationStatusGroupCard(polls: polls)
        case .taskGroup(let ops):
            TaskListCard(ops: ops)
        case .image(let img, let cap):
            InlineImageView(image: img, caption: cap)
                .railHead(.top(14))
        case .compaction(let info):
            // By the call, where there is one: the live and history copies of
            // a compaction are one event, whichever of them is drawn.
            ContextCompactionDivider(info: info)
                .disclosureRoot(info.callID.map { "compaction-\($0)" } ?? node.id)
        case .footer(let turn, let questionID):
            TurnFooter(turn: turn, questionID: questionID, forkPoint: node.forkPoint)
        case .plan(let entries, let streaming):
            LivePlanView(entries: entries, isStreaming: streaming)
        case .thinking:
            ThinkingShimmer()
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
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let text):
                    MarkdownText(raw: text)
                        .multilineTextAlignment(.leading)
                case .image(let image):
                    InlineImageView(image: image, caption: nil)
                default:
                    ContentBlockView(block: block)
                        .disclosureScope("block\(index)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.14), in: UserBubbleShape())
        .overlay(UserBubbleShape().strokeBorder(Theme.accent.opacity(0.30), lineWidth: 0.75))
    }
}

/// The user's bubble, rounded all the way: a pill while the message is one
/// line, and as round a corner as a pill's when it runs longer.
struct UserBubbleShape: InsettableShape {
    /// A one-line bubble's half height, so the two read as one family.
    var radius: CGFloat = 22
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let r = max(0, radius - inset)
        if rect.height <= 2 * r + 1 {
            return Capsule(style: .continuous).path(in: rect)
        }
        return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect)
    }

    func inset(by amount: CGFloat) -> UserBubbleShape {
        var shape = self
        shape.inset += amount
        return shape
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

/// A subtle three-dot shimmer holding the place of a reply's first step until
/// it lands. It sits under the reply's header in a capsule like the header's,
/// so the dots line up under the header's label — bare at the column's edge,
/// they stood out to the left of it. Static under Reduce Motion.
struct ThinkingShimmer: View {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            // An unseen line of the header's type gives the capsule the
            // header's height and a first baseline, which the rail marker
            // lines up with as it does with the header's.
            Text(verbatim: "\u{200B}")
                .font(ReplyHeaderView.labelFont)
                .accessibilityHidden(true)
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
        }
        .padding(ReplyHeaderView.capsuleInsets)
        .background(Theme.surfaceNested, in: Capsule())
        .onAppear { if !reduceMotion { phase = true } }
    }
}

/// The context-compaction boundary (web `ContextCompactionCard`): a hairline
/// running the content width with a small archive glyph + label centered on it.
/// Deliberately chrome-less (no card, no border) — it marks "the conversation's
/// context was compacted here", it is not something the agent *did*.
///
/// The before/after token counts show only for a real reduction (a no-op delta
/// would read as a bug; codex sends none), the time it took once it is done. A
/// failure — the call's own, or an `error` in the versioned payload — says so
/// in the danger tint. What the web keeps for a tooltip (the adapter's error
/// text, else the trigger) is the accessibility hint and a pointer tooltip. A
/// summary the server claims for the call opens beneath the rule, collapsed by
/// default so the boundary stays one line.
struct ContextCompactionDivider: View {
    let info: CompactionInfo

    /// The summary's toggle, kept across the list recycling the row.
    @DisclosureChoice("summary") private var summaryChoice: Bool?
    private var summaryOpen: Bool { summaryChoice ?? false }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func format(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private var label: Text {
        if info.failed { return Text("Context compaction failed") }
        if info.running { return Text("Compacting context…") }
        if let before = info.before, let after = info.after, before != after {
            return Text("Context compacted · \(format(before)) → \(format(after)) tokens")
        }
        return Text("Context compacted")
    }

    /// Only once it is done, and never for a failure.
    private var duration: String? {
        info.failed || info.running ? nil : ContextCompaction.formatDuration(info.durationMs)
    }

    /// Why it happened — the web's tooltip: the error text, else the trigger
    /// (translated when it is one of the known ones, verbatim otherwise).
    private var hint: String? {
        if let error = info.error { return error }
        guard let trigger = info.trigger else { return nil }
        switch ContextCompaction.Trigger(trigger) {
        case .manual:
            return String(localized: "Manually triggered", comment: "Context compaction: the user ran it")
        case .automatic:
            return String(localized: "Automatically triggered", comment: "Context compaction: the agent ran it on its own")
        case .idle:
            return String(localized: "Triggered while idle, before the prompt cache expired",
                          comment: "Context compaction: run on an idle session before its prompt cache expired")
        case .other(let raw):
            return raw
        }
    }

    var body: some View {
        let summary = info.summary
        VStack(spacing: 4) {
            // One line when the label and the toggle both fit; on a phone the
            // token counts often don't leave room, and truncating them to
            // "41,20…" says less than giving the toggle a line of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    hairline
                    marker
                    if summary != nil { summaryToggle }
                    hairline
                }
                VStack(spacing: 2) {
                    HStack(spacing: 10) {
                        hairline
                        marker
                        hairline
                    }
                    if summary != nil { summaryToggle }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)

            if let summary, summaryOpen {
                CompactionSummaryPanel(summary: summary, streaming: info.running)
                    .transition(.opacity)
            }
        }
    }

    private var marker: some View {
        let hint = self.hint ?? ""
        return HStack(spacing: 5) {
            Image(systemName: "archivebox")
                .font(.system(size: 11, weight: .medium))
            label
                .font(Theme.Typography.metaLabel)
            if let duration {
                Text(verbatim: "· \(duration)")
                    .font(Theme.Typography.metaLabel.monospacedDigit())
                    .opacity(0.75)
            }
        }
        .foregroundStyle(info.failed ? Theme.danger : Theme.textTertiary)
        .opacity(info.running ? 0.65 : 1)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: hint))
        .help(Text(verbatim: hint))
    }

    private var summaryToggle: some View {
        Button {
            withAnimation(Theme.Motion.expand) { summaryChoice = !summaryOpen }
        } label: {
            HStack(spacing: 2) {
                Text("Summary")
                Image(systemName: summaryOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(Theme.Typography.metaLabel)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityValue(summaryOpen ? Text("Expanded") : Text("Collapsed"))
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// A compaction's retained summary, opened under its divider: markdown on a
/// faint panel, clamped like the other long transcript bodies (web `max-h-72`
/// + `useCollapsibleOverflow`), with a Show more / Show less footer once it is
/// actually clipped.
private struct CompactionSummaryPanel: View {
    let summary: String
    /// The compaction is still running: the summary may still be arriving.
    let streaming: Bool

    /// Show more, kept across the list recycling the row.
    @DisclosureChoice("summary.more") private var choice: Bool?
    private var expanded: Bool { choice ?? false }
    /// The body's natural height, measured unclamped.
    @State private var contentHeight: CGFloat = 0

    /// web `max-h-72`: 18rem.
    private static let clampHeight: CGFloat = 288

    private var overflowing: Bool { contentHeight > Self.clampHeight }
    private var clipped: Bool { overflowing && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownContent(raw: summary, streaming: streaming)
                // Measured at its natural height whatever the clamp offers it,
                // so "is it clipped" never depends on whether it is clipped.
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .frame(maxHeight: clipped ? Self.clampHeight : nil, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    if clipped {
                        LinearGradient(colors: [Theme.surfaceNested.opacity(0), Theme.surfaceNested],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 44)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if overflowing {
                Divider().overlay(Theme.hairline)
                Button {
                    withAnimation(Theme.Motion.expand) { choice = !expanded }
                } label: {
                    HStack(spacing: 4) {
                        expanded ? Text("Show less") : Text("Show more")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm)
    }
}

/// Inline error banner shown at the tail of a turn that errored or was cancelled.
struct InlineTurnError: View {
    let message: String
    /// Server-supplied diagnostic evidence (agent stderr tail, unparsed-update
    /// counts). Kept behind a disclosure and out of the one-line message: it is
    /// multi-line raw agent output, and only useful once the user asks why.
    var details: String?

    /// The details' toggle, kept across the list recycling the row.
    @DisclosureChoice("details") private var detailsChoice: Bool?
    private var detailsExpanded: Bool { detailsChoice ?? false }

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
            withAnimation(Theme.Motion.expand) { detailsChoice = !detailsExpanded }
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
