import SwiftUI

/// How the sheet reaches the network. Published into the environment by
/// `SessionDetailView`, which owns the client — the same shape as
/// `TranscriptScrollAction`, and for the same reason: a tool card sits many
/// levels down inside the transcript and has no business holding a `CodegClient`.
struct AgentSessionLoader {
    /// A session by its NATIVE id (a grok sub-agent).
    let load: @MainActor (AgentType, String) async throws -> AgentSessionDetail
    /// A codeg conversation by its row id (a delegated task's child).
    var loadConversation: @MainActor (Int) async throws -> ConversationDetail = { _ in
        throw APIError.transport("No session loader in this context")
    }
}

private struct AgentSessionLoaderKey: EnvironmentKey {
    // Never reached in the app: `SessionDetailView` installs a real loader
    // wherever a tool card can be rendered. Failing loudly beats a silent
    // forever-spinner if a future surface forgets to.
    static let defaultValue = AgentSessionLoader(load: { _, _ in
        throw APIError.transport("No session loader in this context")
    })
}

extension EnvironmentValues {
    var agentSessionLoader: AgentSessionLoader {
        get { self[AgentSessionLoaderKey.self] }
        set { self[AgentSessionLoaderKey.self] = newValue }
    }
}

/// Read-only viewer for a sub-agent that ran as a session of its own.
///
/// Grok is the case this exists for: `spawn_subagent` starts a FULL, standalone
/// session and forwards none of the child's chunks or tool calls over ACP, so
/// there is nothing to stream into the parent transcript. But the child writes
/// its transcript to disk as it works, and `get_conversation` parses any session
/// by its native id — sub-agent sessions are hidden from every listing, direct
/// opens still resolve. Re-reading that file on a timer is therefore a real live
/// view of a running child, and the same call serves a finished one.
///
/// Deliberately NOT `TranscriptView`: that one is bound to a codeg conversation
/// row, a send path and a live ACP connection, and a grok sub-agent has none of
/// those. It renders the parsed turns through the same timeline primitives the
/// main transcript uses for each node, so the two read alike.
struct SubAgentSessionSheet: View {
    /// Where the child's transcript is read from.
    enum Source: Equatable {
        /// A session by its native id (`get_conversation`): a grok sub-agent.
        case native(String)
        /// A codeg conversation (`get_folder_conversation`): a delegated
        /// task's child, which codeg tracks as a conversation of its own.
        case conversation(Int)
    }

    let source: Source
    let agentType: AgentType
    /// The child's declared type ("explore", "plan", …) — its subtitle, since a
    /// sub-agent session has no user-set title.
    var subagentType: String?
    /// What the parent asked this child to do.
    var task: String?
    /// Keep re-reading while true (the launching call hasn't settled).
    var live: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.agentSessionLoader) private var loader

    @State private var detail: Loaded?
    @State private var failure: String?

    /// What the sheet draws, whichever source it came from.
    private struct Loaded {
        var turns: [MessageTurn]
        var title: String?
        var model: String?
        /// The child's running round, when its source can say (a codeg
        /// conversation); a native session reports none.
        var inFlightUserTurnId: String?
    }

    init(source: Source, agentType: AgentType, subagentType: String? = nil, task: String? = nil, live: Bool) {
        self.source = source
        self.agentType = agentType
        self.subagentType = subagentType
        self.task = task
        self.live = live
    }

    init(sessionId: String, agentType: AgentType, subagentType: String? = nil, task: String? = nil, live: Bool) {
        self.init(source: .native(sessionId), agentType: agentType, subagentType: subagentType,
                  task: task, live: live)
    }

    /// Re-parse cadence while the parent card says the child is still working.
    /// The child appends continuously; this is one file parse, and it stops the
    /// moment the card settles or the sheet closes.
    private static let refreshInterval: Duration = .seconds(2)

    var body: some View {
        NavigationStack {
            content
                .background(CodegBackground())
                .navigationTitle("Sub-agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        // One task for both the first read and the refresh loop, so it is torn
        // down with the sheet. `live` is captured per-appearance on purpose: a
        // child that settles while the sheet is open keeps polling until the
        // sheet closes, which is cheap and avoids missing the final turns.
        .task {
            await reload()
            guard live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                if Task.isCancelled { return }
                await reload()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            transcript(detail)
        } else if let failure {
            // A child whose session file isn't there yet (grok stamps the id on
            // the spawn notification, before the directory exists) reads as an
            // error; it resolves itself on the next tick while `live`.
            InlineErrorView(message: failure) { Task { await reload() } }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcript(_ detail: Loaded) -> some View {
        List {
            header(detail)
                .modifier(SubAgentRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))

            ForEach(nodes(detail)) { node in
                TimelineRailRow(
                    marker: node.marker,
                    connectTop: node.connectTop,
                    connectBottom: node.connectBottom,
                    startsGroup: node.startsGroup
                ) {
                    NodeBody(node: node)
                }
                .modifier(SubAgentRowChrome())
                .id(node.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // A sub-agent's timeline does not fold; its headers must not reach
        // for the parent session's fold state.
        .environment(\.replyFoldStore, nil)
        // Nor for the parent's disclosures: the child's turn ids are its own
        // and can repeat the parent's, so its rows keep their own state.
        .environment(\.disclosureStore, nil)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private func nodes(_ detail: Loaded) -> [TimelineNode] {
        // `.status` rather than `.round`: this transcript has no round anchor —
        // `get_conversation` reports no in-flight turn — and grok pairs every
        // call with a placeholder result, so an unfinished one arrives matched
        // and only its own `status` can say it is still working. Dropped to
        // `.settled` once the parent call settles, so a child that was
        // interrupted stops showing a spinner nothing will ever clear.
        var all = TranscriptTimeline.buildPersisted(
            turns: detail.turns, pending: [], agent: agentType,
            suppressInFlight: false, inFlightUserTurnId: detail.inFlightUserTurnId,
            liveness: live && detail.inFlightUserTurnId == nil ? .status : .settled
        )
        if !all.isEmpty {
            all[0].connectTop = false
            all[all.count - 1].connectBottom = false
        }
        return all
    }

    private func header(_ detail: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(agent: agentType, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: subagentType ?? detail.title ?? fallbackTitle)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let model = detail.model {
                        Text(verbatim: model)
                            .font(Theme.Typography.metaLabel)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 4)
                if live { LivePulse() }
            }
            if let task, !task.isEmpty {
                Text(verbatim: task)
                    .font(Theme.Typography.metaLabel)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fallbackTitle: String {
        switch source {
        case .native(let id): return id
        case .conversation(let id): return "#\(id)"
        }
    }

    private func reload() async {
        do {
            switch source {
            case .native(let sessionId):
                let read = try await loader.load(agentType, sessionId)
                detail = Loaded(turns: read.turns, title: read.summary.title, model: read.summary.model)
            case .conversation(let id):
                let read = try await loader.loadConversation(id)
                detail = Loaded(turns: read.turns, title: read.summary.trimmedTitle, model: read.summary.model,
                                inFlightUserTurnId: read.inFlightUserTurnId)
            }
            failure = nil
        } catch {
            // Keep whatever is already on screen: a transient failure mid-poll
            // must not blank a transcript the user is reading.
            if detail == nil {
                failure = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The transcript rows' chrome, matching `TranscriptView`'s so the sub-agent's
/// timeline lines up the same way (the rail background has to span the
/// inter-node spacing, so vertical insets stay at 0).
private struct SubAgentRowChrome: ViewModifier {
    var top: CGFloat = 0
    var leading: CGFloat = TimelineMetrics.rowLeadingInset

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: top, leading: leading, bottom: 0, trailing: TimelineMetrics.rowTrailingInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
