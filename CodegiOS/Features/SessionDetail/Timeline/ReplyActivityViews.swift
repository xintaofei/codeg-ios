import SwiftUI

// The activity timeline's reply-level rows (codeg 0.44 web parity): the header
// capsule each reply opens with, the fold-back foot under its rows, and the
// thought / group rows. Tool rows still draw through `ToolCallCard`.

/// The fold store, for the reply headers and feet — absent where replies do
/// not fold (the sub-agent viewer).
private struct ReplyFoldStoreKey: EnvironmentKey {
    static let defaultValue: ReplyFoldStore? = nil
}

extension EnvironmentValues {
    var replyFoldStore: ReplyFoldStore? {
        get { self[ReplyFoldStoreKey.self] }
        set { self[ReplyFoldStoreKey.self] = newValue }
    }
}

enum ReplyActivityText {
    /// `14 steps · 1 failed, recovered · 2 interrupted` — the count first, then
    /// how the reply ended. The breakdown by kind is not on the line (the web
    /// keeps it for a tooltip), so the capsule stays short.
    static func summaryLine(_ summary: ActivitySummary) -> [(text: String, danger: Bool)] {
        var pieces: [(String, Bool)] = []
        if summary.steps > 0 {
            pieces.append((String(localized: "\(summary.steps) steps", comment: "Activity header: number of steps"), false))
        }
        if summary.failed > 0 {
            if summary.unrecovered > 0 {
                pieces.append((String(localized: "\(summary.unrecovered) failed", comment: "Activity header: unrecovered failures"), true))
            } else {
                pieces.append((String(localized: "\(summary.failed) failed, recovered", comment: "Activity header: failures a later step redid"), false))
            }
        }
        if summary.interrupted > 0 {
            pieces.append((String(localized: "\(summary.interrupted) interrupted", comment: "Activity header: interrupted calls"), false))
        }
        return pieces
    }
}

/// `Activity 14 steps · 1 failed · 3m 34s ›` — the capsule a reply opens with.
/// Reads `Working` while the reply runs, and `Reply` for one with no steps, so
/// the slot never blinks in and out as a reply settles. Tapping it folds the
/// reply's process away (when it can fold); the answer stays.
struct ReplyHeaderView: View {
    let header: TimelineNode.ReplyHeader
    let open: Bool
    let currentRound: Bool

    @Environment(\.replyFoldStore) private var store
    /// A delegation's child can finish — or fail — after its reply settled:
    /// the header counts it as its card stands.
    @Environment(\.activityLive) private var live

    private var label: LocalizedStringKey {
        !header.completed ? "Working" : (header.hasSteps ? "Activity" : "Reply")
    }

    /// The capsule's type and insets — shared with the dots that hold the
    /// place of the reply's first step under it (``ThinkingShimmer``), so they
    /// sit in a capsule like this one, lined up under its label.
    static let labelFont = Font.caption.weight(.semibold)
    static let capsuleInsets = EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)

    var body: some View {
        let toggles = header.foldable && store != nil
        Button {
            guard toggles else { return }
            withAnimation(Theme.Motion.expand) {
                store?.setOpen(!open, key: header.replyKey, isCurrent: currentRound)
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(Self.labelFont)
                    .foregroundStyle(Theme.Step.label)
                ForEach(Array(ReplyActivityText.summaryLine(live.summary(of: header)).enumerated()), id: \.offset) { _, piece in
                    Text(verbatim: piece.text)
                        .font(.caption)
                        .foregroundStyle(piece.danger ? Theme.danger : Theme.Step.subject)
                        .lineLimit(1)
                }
                if header.completed, let ms = header.durationMs, ms > 0 {
                    Text(verbatim: DurationFormat.short(ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                if toggles {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(Self.capsuleInsets)
            .background(Theme.surfaceNested, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!toggles)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(toggles ? .isButton : [])
        .accessibilityValue(toggles ? (open ? Text("Expanded") : Text("Collapsed")) : Text(""))
    }
}

/// `Collapse · 14 steps · 3m 34s` under an unfolded reply's rows.
struct ReplyFootView: View {
    let header: TimelineNode.ReplyHeader
    let currentRound: Bool

    @Environment(\.replyFoldStore) private var store

    var body: some View {
        if let store {
            Button {
                withAnimation(Theme.Motion.expand) {
                    store.setOpen(false, key: header.replyKey, isCurrent: currentRound)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                    Text("Collapse")
                    if header.summary.steps > 0 {
                        Text(verbatim: "· " + String(localized: "\(header.summary.steps) steps", comment: "Activity header: number of steps"))
                    }
                    if header.completed, let ms = header.durationMs, ms > 0 {
                        Text(verbatim: "· " + DurationFormat.short(ms))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The agent's reasoning between its calls (web `ThoughtRow`): one line —
/// `Thought  Checking the auth flow ›` — named by what it is about, opening onto
/// the full text. Folded by default; it is the agent's voice between its calls,
/// not something the reader has to see.
struct ThoughtNodeBody: View {
    let text: ActivityText
    let streaming: Bool

    var body: some View {
        switch text {
        case .settled(let s):
            ThoughtRow(text: s, streaming: false)
        case .live(let run, _):
            LiveThought(run: run, streaming: streaming)
        }
    }

    /// Reads the run's text itself, so streaming re-renders only this row.
    private struct LiveThought: View {
        @Bindable var run: LiveTextRun
        let streaming: Bool
        var body: some View { ThoughtRow(text: run.text, streaming: streaming) }
    }
}

/// The open panel is the reasoning minus the heading the row already shows
/// (web `ThoughtRow`: `thoughtBodyWithoutTitle(…).trim()`); a thought that is
/// nothing but its heading has no panel, so the row does not open. Opened, it
/// stays open when the list recycles the row (``DisclosureStore``).
private struct ThoughtRow: View {
    let text: String
    let streaming: Bool

    @DisclosureChoice("thought") private var choice: Bool?
    private var expanded: Bool { choice ?? false }

    var body: some View {
        let row = ThoughtTitle.row(text, streaming: streaming)
        let title = row.title
        let detail = row.body
        let expandable = !detail.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(streaming
                     ? String(localized: "activity.thinking", defaultValue: "Thinking", comment: "Thought row: a thought still being written")
                     : String(localized: "Thought"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Step.label)
                if let title {
                    Text(verbatim: title)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Step.subject)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if expandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                withAnimation(Theme.Motion.expand) { choice = !expanded }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(expandable ? .isButton : [])
            .accessibilityValue(expandable ? (expanded ? Text("Expanded") : Text("Collapsed")) : Text(""))

            if expanded && expandable {
                Group {
                    if streaming {
                        MarkdownText(raw: detail, color: Theme.textSecondary, plain: true)
                    } else {
                        MarkdownContent(raw: detail)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
