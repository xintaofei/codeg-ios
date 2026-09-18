import SwiftUI

/// The session detail transcript: header, live-streaming message transcript, and
/// a pinned compose bar. This is the app's showcase screen — the agent's reply
/// streams in token-by-token over a WebSocket and renders as it arrives.
///
/// Two entry modes share the screen: an existing conversation (loads the
/// transcript), and a brand-new task (fires the first prompt immediately and
/// adopts the conversation the server links). Initializer signatures are
/// contractually stable (constructed by the navigation layer); the view owns a
/// `@MainActor @Observable` model that does all the networking, streaming, and
/// event→UI mapping.
struct SessionDetailView: View {
    let server: ServerProfile
    let client: CodegClient
    /// Open a new draft session (used when the branch switcher resolves a branch
    /// to another worktree folder). `nil` where the host can't navigate.
    let onOpenSession: ((NewSessionRequest) -> Void)?

    @State private var model: SessionDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Set on any `.background` frame, consumed on the next `.active` — see the
    /// `onChange(of: scenePhase)` below for why this beats comparing adjacent phases.
    @State private var wasBackgrounded = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDetails = false
    @State private var showDeleteConfirm = false

    init(server: ServerProfile, client: CodegClient, conversationID: Int,
         onOpenSession: ((NewSessionRequest) -> Void)? = nil) {
        self.server = server
        self.client = client
        self.onOpenSession = onOpenSession
        _model = State(initialValue: SessionDetailViewModel(client: client, conversationID: conversationID))
    }

    init(server: ServerProfile, client: CodegClient, newSession request: NewSessionRequest,
         onOpenSession: ((NewSessionRequest) -> Void)? = nil) {
        self.server = server
        self.client = client
        self.onOpenSession = onOpenSession
        _model = State(initialValue: SessionDetailViewModel(client: client, newSession: request))
    }

    /// Localized nav title: a real session title renders verbatim (user data,
    /// never localized); the unnamed / new-task / loading fallbacks localize.
    private var navTitle: Text {
        if let t = model.summary?.trimmedTitle { return Text(verbatim: t) }
        if model.summary != nil { return Text("Untitled session") }
        return model.isNewSession ? Text("New Task") : Text("Session")
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The agent avatar (formerly in the compose bar) sits to the right of
            // the title. Shown once loaded; for an editable draft its sheet also
            // hosts the Agent + Folder pickers, otherwise just Mode/config.
            if case .loaded = model.phase {
                ToolbarItem(placement: .topBarTrailing) {
                    AgentOptionsButton(
                        agentType: model.agentTypeForUI,
                        workingDir: model.folder?.path,
                        isBusy: model.isInFlight,
                        options: model.agentOptions,
                        newSession: model.isDraftEditable ? NewSessionAgentConfig(
                            availableAgents: model.availableAgents,
                            selectedAgent: model.agentTypeForUI,
                            onSelectAgent: { model.selectAgent($0) },
                            availableFolders: model.availableFolders,
                            selectedFolder: model.folder,
                            onSelectFolder: { model.selectFolder($0) }
                        ) : nil,
                        branch: SessionBranchConfig(
                            // Root repo name when this session lives in a worktree.
                            folderName: model.displayFolderName,
                            folderPath: model.folder?.path,
                            current: model.currentBranch,
                            load: { await model.loadBranches() },
                            switchTo: { await model.switchBranch($0, isRemote: $1) },
                            create: { await model.createBranch($0, from: $1) },
                            onOpenSession: { folderID in
                                onOpenSession?(NewSessionRequest(preselectedFolderID: folderID))
                            }
                        )
                    )
                }
                // A "…" actions menu sits just after the agent avatar, available
                // once the conversation is server-linked. Hosts rename / pin /
                // details / status / delete (mirrors codeg web's per-conversation
                // menu). The session banner used to carry this identity inline;
                // it now lives behind "Session Details".
                if model.canManageConversation {
                    ToolbarItem(placement: .topBarTrailing) {
                        SessionActionsMenu(
                            model: model,
                            onRename: {
                                renameText = model.summary?.title ?? ""
                                showRename = true
                            },
                            onShowDetails: { showDetails = true },
                            onDelete: { showDeleteConfirm = true }
                        )
                    }
                }
            }
        }
        .alert("Rename Session", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") { Task { await model.rename(to: renameText) } }
        } message: {
            Text("Enter a new name for this session.")
        }
        .alert("Delete Session?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { if await model.deleteConversation() { dismiss() } }
            }
        } message: {
            Text("“\(model.summary?.displayTitle ?? "This session")” will be permanently deleted. This can't be undone.")
        }
        .sheet(isPresented: $showDetails) {
            if let summary = model.summary {
                SessionDetailsSheet(summary: summary, stats: model.sessionStats, folder: model.folder)
            }
        }
        .task { await model.load() }
        .onDisappear { model.teardown() }
        // The live WebSocket is suspended (and often killed outright) while
        // backgrounded, so returning here otherwise leaves a frozen transcript
        // until the user backs all the way out and re-enters. Returning from the
        // background almost always lands on `.active` via an intermediate
        // `.inactive` frame first (`.background` -> `.inactive` -> `.active`), so
        // comparing only the immediately-prior phase misses most real resumes —
        // `wasBackgrounded` instead remembers that a `.background` frame happened
        // at all since the last refresh, however many `.inactive` frames follow it.
        // A sheet/alert/control-center pull's `.active` -> `.inactive` -> `.active`
        // blip never sets the flag, so it still won't trigger a spurious refresh.
        .onChange(of: scenePhase) { _, new in
            switch new {
            case .background:
                wasBackgrounded = true
            case .active where wasBackgrounded:
                wasBackgrounded = false
                Task { await model.refreshOnForeground() }
            default:
                break
            }
        }
        // Haptics — the app's marquee "felt" moments, all keyed off existing
        // @Observable state. Vocabulary: success = a reply completed, error = it
        // failed, warning = the agent needs you (a permission / question card
        // appeared), selection = pin / status toggles. The send impact lives in
        // ComposeBar (fired on the tap itself, for immediate feedback).
        .sensoryFeedback(.success, trigger: model.completedTurnTick)
        .sensoryFeedback(trigger: model.sendState) { _, new in
            if case .error = new { return .error }
            return nil
        }
        .sensoryFeedback(trigger: model.pendingPermission?.requestId) { _, new in
            new != nil ? .warning : nil
        }
        .sensoryFeedback(trigger: model.pendingQuestion?.questionId) { _, new in
            new != nil ? .warning : nil
        }
        .sensoryFeedback(trigger: model.pendingPlanApproval?.approvalId) { _, new in
            new != nil ? .warning : nil
        }
        .sensoryFeedback(.selection, trigger: model.userToggleTick)
    }

    private var content: some View {
        // Cross-fade loading ↔ loaded ↔ error instead of a hard cut — after a
        // network round-trip the spinner dissolving into the transcript reads far
        // calmer than a single-frame swap.
        Group {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading session…")
            case .failed(let message):
                InlineErrorView(message: message) {
                    Task { await model.load() }
                }
            case .loaded:
                loadedBody
            }
        }
        .transition(.opacity)
        .animation(Theme.Motion.content, value: model.phase)
    }

    private var loadedBody: some View {
        TranscriptView(
            turns: model.turns,
            pendingUserTurns: model.pendingUserTurns,
            liveTurn: model.liveTurn,
            liveOwnsInFlightReply: model.liveTurnFromReattach,
            agent: model.agentTypeForUI,
            turnsVersion: model.turnsVersion,
            scrollTick: model.scrollTick,
            stickTick: model.stickTick,
            onPinnedChange: { model.setPinnedToBottom($0) }
        ) {
            // No top banner on an existing session — its identity + stats now
            // live in the nav-bar "…" → Session Details, so messages start at
            // the top and pass under the frosted nav bar (ChatGPT-style). A
            // brand-new task still shows a compact setup card until the server
            // links a conversation.
            VStack(spacing: 12) {
                if model.summary == nil, model.isNewSession {
                    NewSessionHeaderCard(
                        agent: model.selectedAgent,
                        folder: model.folder,
                        isStarting: model.hasStartedFirstSend
                    )
                }
                if model.isEmptyTranscript {
                    EmptyStateView(
                        icon: "bubble.left.and.text.bubble.right",
                        title: "No messages yet",
                        message: "Send a message to start this session."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.28), value: model.pendingUserTurns)
        .animation(.snappy(duration: 0.28), value: model.liveTurn?.id)
        .safeAreaInset(edge: .bottom) {
            // The "jump to latest" affordance sits in the compose-bar inset — not
            // as a `List` overlay — so it is reliably above the bar and tappable
            // (an overlay anchored to the scroll view's bottom rendered *under* the
            // compose bar, which silently ate the tap). It is horizontally centered
            // and only present while the user has scrolled up.
            VStack(spacing: 0) {
                // Interactive prompt cards sit above everything in the inset: the
                // agent has paused and the user's next action is to respond here.
                // Fade only (no geometry transition) so the buttons' hit regions
                // aren't offset mid-animation. `.id` resets per-card state when a
                // fresh request replaces a showing one.
                if let pending = model.pendingPermission {
                    PermissionRequestCard(pending: pending) { optionId in
                        await model.respondPermission(optionId: optionId)
                    }
                    .id(pending.requestId)
                    .transition(.opacity)
                    .zIndex(2)
                }
                if let question = model.pendingQuestion {
                    AskQuestionCard(pending: question) { answer in
                        await model.answerQuestion(answer)
                    }
                    .id(question.questionId)
                    .transition(.opacity)
                    .zIndex(2)
                }
                if let approval = model.pendingPlanApproval {
                    PlanApprovalCard(pending: approval) { decision, feedback in
                        await model.answerPlanApproval(decision: decision, feedback: feedback)
                    }
                    .id(approval.approvalId)
                    .transition(.opacity)
                    .zIndex(2)
                }
                if !model.isPinnedToBottom {
                    JumpToLatestButton { model.userTappedScrollToBottom() }
                        .padding(.bottom, 10)
                        // Fade only — a `.scale` transition is scaleEffect-backed
                        // and can leave a residual transform that offsets the
                        // button's hit region from its pixels (the tap then falls
                        // through to the message text behind it). `zIndex` keeps it
                        // above the compose bar's glass during the cross-fade.
                        .transition(.opacity)
                        .zIndex(1)
                }
                ComposeBar(
                    text: $model.draft,
                    isInFlight: model.isInFlight,
                    notice: model.notice,
                    attachments: model.attachments,
                    canAttachMore: model.canAttachMore,
                    onAddAttachments: { model.addAttachments($0) },
                    onRemoveAttachment: { model.removeAttachment($0) },
                    onNotice: { model.notice = $0 },
                    onSend: { model.send() },
                    onStop: { model.cancel() },
                    onDismissNotice: { model.notice = nil },
                    insertModel: model.insertModel
                )
            }
            .animation(.snappy(duration: 0.24), value: model.isPinnedToBottom)
            .animation(.snappy(duration: 0.26), value: model.pendingPermission?.id)
            .animation(.snappy(duration: 0.26), value: model.pendingQuestion?.id)
            .animation(.snappy(duration: 0.26), value: model.pendingPlanApproval?.id)
        }
    }
}

/// A floating glass affordance that re-pins the transcript to the newest message,
/// shown only while the user has scrolled up. Mirrors ChatGPT/Claude.
private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: Circle())
                .hairlineBorder(20)
                // An explicit hit shape so the whole disc is tappable (and the
                // tap can't slip past its edge into the transcript underneath).
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest")
    }
}

/// Identity card shown atop a new task before the server links a conversation
/// (the full `SessionHeaderView` takes over once the summary arrives). Reflects
/// the draft's chosen agent + folder, which are edited from the agent button in
/// the navigation bar until the first send.
private struct NewSessionHeaderCard: View {
    let agent: AgentType?
    let folder: FolderDetail?
    let isStarting: Bool

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 14) {
            HStack(spacing: 10) {
                if let agent {
                    AgentBadge(agent: agent)
                }
                if let folder {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9, weight: .semibold))
                        Text(folder.name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
                Spacer(minLength: 0)
                (isStarting ? Text("Starting…") : Text("Tap the agent avatar above to set up"))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }
}

// MARK: - Actions menu

/// The nav-bar "…" menu of per-conversation actions, mirroring codeg web's
/// per-conversation context menu: rename, pin, details, status, delete. Presented
/// just after the agent avatar once the conversation is server-linked.
private struct SessionActionsMenu: View {
    let model: SessionDetailViewModel
    let onRename: () -> Void
    let onShowDetails: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button { Task { await model.togglePin() } } label: {
                if model.isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin")
                }
            }
            Button(action: onShowDetails) {
                Label("Session Details", systemImage: "info.circle")
            }
            Menu {
                ForEach(ConversationStatus.selectable, id: \.self) { status in
                    Button { Task { await model.setStatus(status) } } label: {
                        if model.currentStatus == status {
                            Label(status.label, systemImage: "checkmark")
                        } else {
                            Text(status.label)
                        }
                    }
                }
            } label: {
                Label("Change Status", systemImage: "circle.dashed")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            // A plain ellipsis (no enclosing circle) reads lighter next to the
            // round agent avatar; the system toolbar glass is the only container.
            Image(systemName: "ellipsis")
                .accessibilityLabel("Session actions")
        }
    }
}

// MARK: - Session details sheet

/// The session identity + stats that used to sit in a top banner, now presented
/// on demand from the actions menu. Reuses `SessionHeaderView` for the identity
/// card and adds workspace / timing metadata.
private struct SessionDetailsSheet: View {
    let summary: ConversationSummary
    let stats: SessionStats?
    let folder: FolderDetail?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SessionHeaderView(summary: summary, stats: stats)
                    metadata
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(CodegBackground())
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var metadata: some View {
        VStack(spacing: 0) {
            DetailRow(label: "Status", value: Text(summary.status.label))
            Divider().overlay(Theme.hairline)
            if let folder {
                DetailRow(label: "Folder", value: Text(verbatim: folder.name))
                Divider().overlay(Theme.hairline)
            }
            DetailRow(label: "Messages", value: Text(verbatim: "\(summary.messageCount)"))
            Divider().overlay(Theme.hairline)
            DetailRow(label: "Created", value: Text(verbatim: summary.createdAt.formatted(date: .abbreviated, time: .shortened)))
            Divider().overlay(Theme.hairline)
            DetailRow(label: "Updated", value: Text(verbatim: summary.updatedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
    }
}

private struct DetailRow: View {
    let label: LocalizedStringKey
    /// A pre-built `Text` so callers can choose verbatim (dynamic data like folder
    /// names/dates) vs. localized (the status label) per row.
    let value: Text

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            value
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
    }
}
