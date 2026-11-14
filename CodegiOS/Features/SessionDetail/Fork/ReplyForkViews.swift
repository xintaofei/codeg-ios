import SwiftUI

// MARK: - Fork action (environment)

/// The fork capability the session screen publishes into the environment, so a
/// reply's footer — deep inside a memoized transcript row — can offer "Fork
/// from here" without the row carrying any of it.
///
/// That is the point of it being an environment value and not row data: the
/// persisted rows are memoized on a content-free key, and the busy state below
/// flips at both ends of every turn. As row data it would rebuild the whole
/// persisted tier each time; here it only re-renders the footers that read it.
///
/// Equal by its flags alone. The closure is rebuilt with every pass of the
/// screen but only ever reaches the same, stable view model, so two values with
/// the same flags behave the same — and a footer is not re-rendered for a new
/// closure that does nothing different.
struct TranscriptForkAction: Equatable {
    /// The conversation's agent — which decides where a fork can be aimed.
    let agent: AgentType
    /// False once a live session said this agent has no `session/fork`.
    let supported: Bool
    /// Something is running (a turn, a fork) — the button greys out rather
    /// than disappearing, so the footer doesn't reflow at both ends of a turn.
    let busy: Bool
    /// Ask to fork at a point (the screen confirms first).
    let request: (ReplyForkPoint) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.supported == rhs.supported && lhs.busy == rhs.busy
    }

    func offers(_ point: ReplyForkPoint) -> Bool {
        supported && point.request(agent: agent) != nil
    }
}

private struct TranscriptForkKey: EnvironmentKey {
    /// Absent everywhere but a server-linked conversation's own transcript.
    static let defaultValue: TranscriptForkAction? = nil
}

extension EnvironmentValues {
    var transcriptFork: TranscriptForkAction? {
        get { self[TranscriptForkKey.self] }
        set { self[TranscriptForkKey.self] = newValue }
    }
}

// MARK: - Open a conversation (environment)

/// Opens another conversation the way every other entry point does
/// (`AppModel.open(.conversation(_:))`): pushed on the current tab's stack on a
/// phone, selected in the detail column on an iPad. Published by the app shell;
/// absent (nil) where nothing can navigate.
struct OpenConversationAction {
    let open: (Int) -> Void
    func callAsFunction(_ conversationID: Int) { open(conversationID) }
}

private struct OpenConversationKey: EnvironmentKey {
    static let defaultValue: OpenConversationAction? = nil
}

extension EnvironmentValues {
    var openCodegConversation: OpenConversationAction? {
        get { self[OpenConversationKey.self] }
        set { self[OpenConversationKey.self] = newValue }
    }
}

// MARK: - Footer button

/// "Fork from here" in a settled reply's footer. Draws nothing where the reply
/// can't be forked at all (see ``ReplyForkPoint/request(agent:)``); greys out
/// while the conversation is busy.
struct ForkReplyButton: View {
    let point: ReplyForkPoint
    @Environment(\.transcriptFork) private var fork

    var body: some View {
        if let fork, fork.offers(point) {
            Button {
                fork.request(point)
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fork.busy)
            .opacity(fork.busy ? 0.4 : 1)
            .accessibilityLabel("Fork from here")
        }
    }
}

// MARK: - Screen chrome

/// What the session screen adds for forking: the action its footers read, and
/// the confirmation that comes before a fork.
///
/// The confirmation is not optional politeness. What a fork does is the
/// opposite of what the word suggests: THIS conversation is the one cut back
/// and renamed, and the untouched original is the new row.
struct ReplyForkChrome: ViewModifier {
    let model: SessionDetailViewModel
    @State private var candidate: ReplyForkPoint?

    func body(content: Content) -> some View {
        content
            .environment(\.transcriptFork, model.canManageConversation ? TranscriptForkAction(
                agent: model.agentTypeForUI,
                supported: model.forkSupported != false,
                busy: !model.canForkNow,
                request: { candidate = $0 }
            ) : nil)
            .alert(
                "Fork from here?",
                isPresented: Binding(
                    get: { candidate != nil },
                    set: { if !$0 { candidate = nil } }
                ),
                presenting: candidate
            ) { point in
                Button("Cancel", role: .cancel) { }
                Button("Fork") { model.forkFromReply(point) }
            } message: { _ in
                Text("This conversation will be cut back to this reply and renamed “[Fork] …”. The full original stays as a separate conversation.")
            }
    }
}

/// Above the composer: a fork on its way, then what it left behind — with the
/// way to the original, which the fork moved to a row of its own.
struct ForkStatusStrip: View {
    let model: SessionDetailViewModel
    @Environment(\.openCodegConversation) private var openConversation

    /// How long the "open the original" line stays up on its own.
    private static let outcomeLifetime: Duration = .seconds(20)

    var body: some View {
        Group {
            if model.isForking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Forking…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .modifier(ForkStripChrome())
            } else if let outcome = model.forkOutcome {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Forked. The full original is kept as a separate conversation.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let openConversation {
                        Button("Open original") {
                            model.dismissForkOutcome()
                            openConversation(outcome.siblingConversationID)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                    }
                    Button {
                        model.dismissForkOutcome()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .modifier(ForkStripChrome())
                // Its own clock, keyed to this outcome: a newer fork restarts it.
                .task(id: outcome.id) {
                    try? await Task.sleep(for: Self.outcomeLifetime)
                    guard !Task.isCancelled else { return }
                    model.dismissForkOutcome(outcome)
                }
            }
        }
        .animation(Theme.Motion.expand, value: model.isForking)
        .animation(Theme.Motion.expand, value: model.forkOutcome)
    }
}

private struct ForkStripChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.35))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.opacity)
    }
}
