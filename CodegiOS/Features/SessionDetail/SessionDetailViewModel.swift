import SwiftUI
import Observation

/// Drives the session detail screen: loads the transcript, sends prompts, and
/// consumes the live ACP event stream — mapping each event onto the in-flight
/// assistant turn. All mutable UI state lives here on the main actor, so there
/// are no data races even though the WebSocket delivers frames concurrently
/// (the consuming `Task` is main-actor isolated, so `for await` hops back to the
/// main actor on every frame).
@MainActor
@Observable
final class SessionDetailViewModel {

    // MARK: - Load phase

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    // MARK: - Inputs

    private let client: CodegClient

    /// What this screen is bound to: an existing conversation, or a brand-new
    /// task that adopts its conversation id from the `conversation_linked`
    /// event after the first prompt.
    private enum Mode {
        case existing(conversationID: Int)
        case new(NewSessionRequest)
    }
    private let mode: Mode

    /// The bound conversation id — fixed for an existing conversation; nil for
    /// a new task until the server links one.
    private(set) var conversationID: Int?
    /// The new-task payload (nil when opened on an existing conversation).
    private(set) var newRequest: NewSessionRequest?

    /// Drives the agent-options sheet (mode + config selectors). Shares this
    /// model's chat connection so applying an option targets the same agent the
    /// next send will reuse.
    let agentOptions: AgentOptionsModel

    /// Backs the compose "+" menu's insert pickers (quick messages / experts /
    /// slash commands). Pure-text inserts — no live connection required.
    let insertModel: ComposeInsertModel

    // MARK: - Observable state

    private(set) var phase: LoadPhase = .loading

    /// Authoritative, persisted turns from the server.
    ///
    /// The `didSet` bumps `turnsVersion` on every mutation (assignment or append)
    /// so the transcript can detect a real persisted change cheaply. `@Observable`
    /// preserves the observer (same pattern as `AppModel.selectedServerID`).
    private(set) var turns: [MessageTurn] = [] {
        didSet { turnsVersion &+= 1 }
    }
    /// Monotonic version of `turns`, bumped on every mutation. A content-free
    /// signal the transcript keys its persisted-node memo on, so streamed tokens
    /// no longer force a re-hash of every visible turn's full text (`MessageTurn`
    /// is content-`Hashable`) just to rebuild the node list.
    private(set) var turnsVersion = 0
    /// Optimistic user turns awaiting persistence (spliced out on re-fetch).
    private(set) var pendingUserTurns: [MessageTurn] = []
    /// The assistant reply currently streaming, if any.
    private(set) var liveTurn: LiveTurn?
    /// Whether `liveTurn` was rebuilt from a reattach snapshot (vs. created by a
    /// local send). On reattach the snapshot's `live_message` is the COMPLETE
    /// in-flight reply, but the agent CLI asynchronously persists a PARTIAL copy
    /// of that same reply into `turns` while it streams — so the transcript must
    /// hide the persisted partial to avoid double-rendering the reply (see
    /// `TranscriptTimeline.buildPersisted`'s `suppressInFlight`). False on the send
    /// path, where the optimistic prompt lives in `pendingUserTurns` and `turns`
    /// carries no trailing in-flight reply to hide. Reset on every send (the one
    /// chokepoint that creates a send live turn), set on every reattach build.
    private(set) var liveTurnFromReattach = false

    /// A pending permission request — or ExitPlanMode — awaiting the user's
    /// choice. Rendered as a card above the compose bar; nil when none is pending.
    private(set) var pendingPermission: PendingPermission?
    /// A pending `ask_user_question` awaiting the user's answers.
    private(set) var pendingQuestion: PendingQuestion?
    /// A pending Grok `exit_plan_mode` awaiting approve / request-changes / abandon.
    private(set) var pendingPlanApproval: PendingPlanApproval?
    /// Revision notes waiting to be sent as a follow-up prompt after a
    /// "request changes" decision (see ``answerPlanApproval(decision:feedback:)``).
    private var pendingPlanFollowUp: String?

    private(set) var summary: ConversationSummary?
    private(set) var sessionStats: SessionStats?
    private(set) var folder: FolderDetail?

    /// The working tree's current git branch (for `folder`), shown + checkmarked
    /// in the branch selector. Seeded from conversation/folder metadata and
    /// updated optimistically on checkout / new-branch.
    private(set) var currentBranch: String?

    // MARK: - Draft new-session selection

    /// The draft's chosen agent (new session only; nil for existing). The
    /// authoritative agent for a linked/existing conversation is the summary's.
    private(set) var selectedAgent: AgentType?
    /// Agents offered in the draft's in-page picker (narrowed to installed/enabled).
    private(set) var availableAgents: [AgentType] = AgentType.allCases
    /// Folders offered in the draft's in-page picker.
    private(set) var availableFolders: [FolderDetail] = []
    /// The full folder set (`list_all_folder_details`), kept so the branch switcher
    /// can resolve a worktree's root and locate a registered target folder by id.
    private(set) var allFolders: [FolderDetail] = []
    /// True once a draft's first send begins — locks the agent/folder pickers.
    private(set) var hasStartedFirstSend = false

    /// Compose-bar text.
    var draft: String = ""

    /// Images staged for the next prompt (added via the "+" menu). Cleared when
    /// the optimistic turn is posted; restored if that send is rolled back.
    private(set) var attachments: [Attachment] = []

    var canAttachMore: Bool {
        attachments.count < AttachmentPrep.maxCount
            && attachments.reduce(0) { $0 + $1.byteCount } < AttachmentPrep.maxTotalBytes
    }

    /// Coarse phase of an in-flight send, for the compose status line.
    enum SendState: Equatable {
        case idle
        case connecting
        case thinking
        case running(tool: String)
        case error(String)
    }
    private(set) var sendState: SendState = .idle

    /// A transient, non-fatal notice (e.g. "a turn is already running").
    var notice: String?

    /// Monotonic token used to scroll-to-bottom; bump it to request a scroll.
    /// The transcript follows this *only while pinned to the bottom* (so streamed
    /// tokens don't yank a user who has scrolled up to read).
    private(set) var scrollTick: Int = 0
    /// Monotonic token that *forces* a re-pin to the bottom regardless of the
    /// user's current scroll position — bumped on the user's own send and on
    /// initial load, where landing at the latest message is always intended.
    private(set) var stickTick: Int = 0
    /// Whether the transcript viewport is parked at the bottom. Reported by the
    /// transcript as the user scrolls; drives the floating "jump to latest" button
    /// (shown when false). Starts true (a fresh open lands at the latest message).
    private(set) var isPinnedToBottom = true
    /// Monotonic token bumped once each time a reply *successfully* finalizes, so
    /// the view can fire a single success haptic. Distinct from `sendState`
    /// reaching `.idle`, which also happens on a pre-acceptance rollback (that
    /// path must NOT feel like success). The error counterpart is `sendState`
    /// transitioning to `.error`, which only `failLive` sets.
    private(set) var completedTurnTick: Int = 0
    /// Monotonic token bumped only when the *user* toggles pin / status, so the
    /// view fires a selection haptic on the action itself. Keying the haptic on the
    /// derived `isPinned` / `currentStatus` instead mis-fires on the async `summary`
    /// load (nil → value), buzzing on every session open.
    private(set) var userToggleTick: Int = 0

    // MARK: - Streaming internals

    private var connectionID: String?
    /// The conversation row THIS draft's first send created up front (via
    /// `create_conversation`). Held until the prompt is accepted; if the send is
    /// rolled back before then, this row is deleted so no empty conversation
    /// lingers on other clients and the draft's pickers re-open.
    private var draftCreatedConversationID: Int?
    private var stream: EventStream?
    /// The outer send pipeline (resolve connection → open stream → prompt).
    private var sendTask: Task<Void, Never>?
    /// The long-lived loop consuming `stream.frames`.
    private var consumerTask: Task<Void, Never>?
    private let subscriptionID = UUID().uuidString
    /// Guards against double-finalizing a turn from racing terminal events.
    private var isTurnActive = false
    /// Bumped every time a new stream is opened. A consumer loop captures the
    /// value at spawn and ignores its own terminal frames once superseded — so
    /// closing an old stream during a stale-connection retry can't end the turn.
    private var streamGeneration = 0
    /// Pending silent reconnect after a transient socket drop (see
    /// `scheduleReconnect`). Cancelled by `closeStream`.
    private var reconnectTask: Task<Void, Never>?
    /// Consecutive reconnect attempts with no frames since the last good one.
    /// Reset whenever the server confirms a fresh attach (a snapshot/replay
    /// frame). Past `maxStreamReconnects`, recovery gives up and reconciles.
    private var streamReconnects = 0
    private static let maxStreamReconnects = 6

    private init(client: CodegClient, mode: Mode) {
        self.client = client
        self.mode = mode
        switch mode {
        case .existing(let id):
            self.conversationID = id
        case .new(let request):
            self.newRequest = request
            // Agent/folder are chosen in-page (from the agent button in the
            // navigation bar); their defaults are resolved in `load()` from the
            // server's folder + agent lists, honoring any preselected folder.
        }
        // Initialize both child models BEFORE wiring any closures: the closures
        // below capture `self`, which Swift only allows once every stored property
        // is initialized.
        self.agentOptions = AgentOptionsModel(client: client)
        self.insertModel = ComposeInsertModel(client: client)
        // Apply actions resolve (and cache) the same chat connection the send
        // flow uses, so a mode/config change targets the agent the next prompt
        // will reuse — and never spawns a second one.
        agentOptions.resolveConnection = { [weak self] in
            guard let self else { throw APIError.transport("Session closed.") }
            return try await self.resolveConnectionForOptions()
        }
        // The authoritative current mode/config for this conversation's live
        // session (nil when none is live). Used to load the sheet and to reconcile
        // after an apply, since the set_* routes only enqueue the change.
        agentOptions.loadSnapshot = { [weak self] in
            guard let self, let id = self.conversationID else { return nil }
            return try await self.client.sessionSnapshot(conversationId: id)
        }

        // Quick messages + experts are connection-independent catalog reads.
        // Slash commands come from the cheap by-conversation snapshot (empty until
        // a connection binds — no agent is spawned to list them).
        insertModel.loadQuickMessagesAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.quickMessages()
        }
        insertModel.loadExpertsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.experts(agentType: self.agentTypeForUI)
        }
        insertModel.loadBuiltInExpertsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.builtInExperts()
        }
        insertModel.loadCommandsAction = { [weak self] in
            guard let self, let id = self.conversationID else { return [] }
            return try await self.client.sessionSnapshot(conversationId: id)?.availableCommands ?? []
        }
        // Backs the compose bar's inline `@`-mention popup — the same catalog
        // read `AgentsSettingsModel` uses, independent of any live connection.
        insertModel.loadAgentsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.listAgents()
        }

    }

    convenience init(client: CodegClient, conversationID: Int) {
        self.init(client: client, mode: .existing(conversationID: conversationID))
    }

    /// A brand-new task: `load()` immediately fires the first prompt composed
    /// in the new-task sheet, and the screen adopts the conversation id the
    /// server links — so the very first reply streams like any other turn.
    convenience init(client: CodegClient, newSession request: NewSessionRequest) {
        self.init(client: client, mode: .new(request))
    }

    // MARK: - Derived

    /// In flight only while the live turn is still streaming. A finalized,
    /// errored, or cancelled live turn stays on screen but is no longer "in
    /// flight", so the compose bar returns to its send state. (Reading the live
    /// turn's `isStreaming` here lets SwiftUI track it transitively.)
    var isInFlight: Bool { liveTurn?.isStreaming == true }

    /// True when there is no content at all to show in the loaded state.
    var isEmptyTranscript: Bool {
        turns.isEmpty && pendingUserTurns.isEmpty && liveTurn == nil
    }

    /// Whether this screen started as a new task (vs. an existing conversation).
    var isNewSession: Bool { newRequest != nil }

    /// The draft's agent/folder are still editable: a new session whose first
    /// send hasn't started yet (after that the conversation is being created).
    var isDraftEditable: Bool { isNewSession && !hasStartedFirstSend }

    /// The agent identity for UI + connection purposes: the loaded summary's
    /// (existing / linked), else the draft's chosen agent.
    var agentTypeForUI: AgentType {
        summary?.agentType ?? selectedAgent ?? .claudeCode
    }

    // MARK: - Load

    /// Guards the one-time draft option load so a re-run of `.task` can't refetch.
    private var didLoadDraftOptions = false

    func load() async {
        switch mode {
        case .existing(let id):
            phase = .loading
            do {
                async let detailReq = client.conversationDetail(id: id)
                async let foldersReq = client.listFolders()
                let detail = try await detailReq
                let folders = try await foldersReq

                summary = detail.summary
                turns = detail.turns
                sessionStats = detail.sessionStats
                allFolders = folders
                folder = folders.first { $0.id == detail.summary.folderId }
                currentBranch = detail.summary.gitBranch ?? folder?.gitBranch
                insertModel.agentType = detail.summary.agentType
                phase = .loaded
                // Initial load lands at the latest message.
                requestStickToBottom()
                // If a turn is still running on this session (started here earlier,
                // from codeg web, or before an app relaunch), attach so it streams
                // live and any pending permission/question card surfaces.
                //
                // Two signals say "a turn is in flight", and we trust EITHER:
                //   • `in_flight_user_turn_id` — precise, but the server only stamps
                //     it when the persisted tail is `[…, User]` or `[…, User,
                //     Assistant]` (see `apply_in_flight_message_id`); it goes nil the
                //     moment the agent persists a second trailing assistant turn
                //     mid-stream — which is exactly what plan mode does (a plan/
                //     reasoning turn, then the partial reply). That nil would strand a
                //     genuinely-streaming session on a static transcript.
                //   • row `status == .inProgress` — coarser but RELIABLE: set
                //     unconditionally when the turn starts and cleared only on
                //     `TurnComplete`, so it stays true for the whole turn (including
                //     while blocked on an ExitPlanMode confirmation).
                // Treating either as live makes reattach retry through a transient
                // discovery miss; the snapshot then decides what's actually running.
                let serverSaysLive = detail.inFlightUserTurnId != nil
                    || detail.summary.status == .inProgress
                await reattachIfLive(serverSaysLive: serverSaysLive)
            } catch {
                phase = .failed(Self.describe(error))
            }

        case .new(let request):
            // A blank draft: show the composer immediately, then populate the
            // folder + agent lists so the in-page pickers (the nav-bar agent
            // button) are ready. Nothing is sent until the user writes + taps send.
            phase = .loaded
            guard !didLoadDraftOptions else { return }
            didLoadDraftOptions = true
            await loadDraftOptions(preselectedFolderID: request.preselectedFolderID)
        }
    }

    /// Populate the draft's folder/agent lists and pick sensible defaults
    /// (preselected folder → most-recent folder; its default agent → first
    /// installed). Failures leave the full `AgentType` fallback in place.
    private func loadDraftOptions(preselectedFolderID: Int?) async {
        // The picker lists top-level open folders only (a new session shouldn't
        // target a worktree directly). The full set resolves a preselected folder
        // that the picker omits — e.g. a worktree the branch switcher just opened a
        // draft in.
        async let openReq = client.listOpenFolders()
        async let allReq = client.listFolders()

        // Narrow agents to what the server actually has installed + enabled.
        if let agents = try? await client.listAgents() {
            let usable = agents.filter { $0.available && $0.enabled }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.agentType)
            var deduped: [AgentType] = []
            for agent in usable where !deduped.contains(agent) { deduped.append(agent) }
            if !deduped.isEmpty { availableAgents = deduped }
        }

        let open = (try? await openReq) ?? []
        let all = (try? await allReq) ?? []
        allFolders = all
        availableFolders = FolderVisibility.filterTopLevel(open)
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        if folder == nil {
            folder = all.first { $0.id == preselectedFolderID } ?? availableFolders.first
        }
        currentBranch = folder?.gitBranch
        if selectedAgent == nil {
            if let preferred = folder?.defaultAgentType, availableAgents.contains(preferred) {
                selectedAgent = preferred
            } else {
                selectedAgent = availableAgents.first
            }
        }
        if let agent = selectedAgent { insertModel.agentType = agent }
    }

    // MARK: - Draft selection (new session only)

    /// Change the draft's agent before the first send. A different agent needs a
    /// different connection, so any one resolved by the options sheet is dropped.
    func selectAgent(_ agent: AgentType) {
        guard isDraftEditable, agent != selectedAgent else { return }
        selectedAgent = agent
        insertModel.agentType = agent
        resetDraftConnection()
    }

    /// Change the draft's folder before the first send. The folder is the agent's
    /// working dir, so a change likewise invalidates any resolved connection.
    func selectFolder(_ newFolder: FolderDetail) {
        guard isDraftEditable, newFolder.id != folder?.id else { return }
        folder = newFolder
        currentBranch = newFolder.gitBranch
        resetDraftConnection()
    }

    /// Drop a connection the options sheet resolved before any send, so the next
    /// option-apply / first prompt re-resolves against the new agent/folder.
    private func resetDraftConnection() {
        connectionID = nil
        agentOptions.teardown()
    }

    // MARK: - Git branch (selector)

    /// List the folder's branches for the branch selector. Returns nil when there
    /// is no folder path (no git context) or the call fails (surfaced via notice).
    /// Also refreshes the current-branch label opportunistically.
    func loadBranches() async -> GitBranchList? {
        guard let path = folder?.path else { return nil }
        do {
            let list = try await client.gitListAllBranches(path: path)
            if let cur = try? await client.gitCurrentBranch(path: path), !cur.isEmpty {
                currentBranch = cur
            }
            return list
        } catch {
            notice = Self.describe(error)
            return nil
        }
    }

    /// The folder name to show in the branch/workspace surface: the ROOT repo's
    /// name when this conversation lives in a worktree (git ops still target the
    /// worktree's own `path`), else the folder's own name. Mirrors the web's
    /// `resolveFolderDisplayName`.
    var displayFolderName: String? {
        guard let folder else { return nil }
        return FolderVisibility.displayName(of: folder, in: allFolders)
    }

    /// Switch to `branch`, worktree-aware (web parity, `planBranchSwitch`):
    /// - the branch isn't checked out anywhere (or it's a remote pick) → `git
    ///   checkout` in the repo root (in place when we're already in the root);
    /// - it lives in another (registered or unregistered) worktree → open a NEW
    ///   draft session in that folder rather than mutating this conversation.
    ///
    /// Returns the navigation intent for the caller (the view performs the actual
    /// navigation since the view model has no nav handle). Surfaces failures via
    /// `notice`.
    func switchBranch(_ branch: String, isRemote: Bool) async -> BranchSwitchOutcome {
        guard let active = folder else { return .failed }
        if branch == currentBranch { return .noop }

        // Find where the branch is checked out (skip for a remote pick — those
        // always check out fresh in the root).
        let resolution: WorktreeResolution? = isRemote
            ? nil
            : try? await client.resolveWorktreeFolder(repoPath: active.path, branch: branch)
        let plan = FolderVisibility.planBranchSwitch(
            active: active, resolution: resolution, allFolders: allFolders, isRemote: isRemote
        )

        switch plan {
        case .noop:
            return .noop

        case .navigateRegistered(let folderId):
            // Already a registered folder — make sure it's open, then navigate.
            if let target = allFolders.first(where: { $0.id == folderId }) {
                _ = try? await client.openFolder(path: target.path)
            }
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: folderId)

        case .navigateExternal(let path, let rootId):
            // Worktree dir not registered yet — register it (parented to the root),
            // then navigate into it.
            guard let detail = try? await client.openWorktreeFolder(path: path, sourceFolderId: rootId) else {
                notice = "Couldn’t open the worktree folder."
                return .failed
            }
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: detail.id)

        case .checkoutInRoot(let root):
            do {
                try await client.gitCheckout(path: root.path, branchName: branch)
            } catch {
                // A plain `git checkout` is refused by git when the branch is
                // already checked out in another worktree ("fatal: '<b>' is already
                // used by worktree at '<path>'"). We only land here when resolution
                // was skipped (a remote pick) or was unavailable, so the branch was
                // never routed to its worktree. Recover the way the web's resolve
                // step would have — locate that worktree and open a session in it —
                // instead of surfacing a dead-end checkout failure. A genuine
                // failure (e.g. a dirty working tree) yields nil and is surfaced.
                if let outcome = await recoverFromWorktreeCheckout(branch: branch, root: root, error: error) {
                    return outcome
                }
                notice = Self.describe(error)
                return .failed
            }
            if root.id == active.id {
                // In place — reflect the ACTUAL resulting HEAD (a remote ref like
                // `origin/x` lands on local `x`).
                if let actual = try? await client.gitCurrentBranch(path: root.path), !actual.isEmpty {
                    currentBranch = actual
                } else {
                    currentBranch = branch
                }
                return .switchedInPlace
            }
            // We were inside a worktree; the checkout happened in the root → open a
            // session there so the user lands on the branch they picked.
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: root.id)
        }
    }

    /// Recover from a `git checkout` that git refused because `branch` is already
    /// checked out in a worktree. Locates that worktree and returns a navigation
    /// intent into it, mirroring what the web's resolve step does up front. Returns
    /// nil when the failure was something else (e.g. a dirty tree) so the caller
    /// surfaces the real error.
    private func recoverFromWorktreeCheckout(branch: String, root: FolderDetail, error: Error) async -> BranchSwitchOutcome? {
        // Preferred: ask the server where the branch lives. This works no matter how
        // we got here — notably a remote ref whose local branch sits in a worktree,
        // where the up-front resolution was deliberately skipped.
        if let resolution = try? await client.resolveWorktreeFolder(repoPath: root.path, branch: branch),
           let path = resolution.path {
            return await openWorktreeSession(path: path, folderId: resolution.folderId, root: root)
        }
        // Fallback for servers without `resolve_worktree_folder`: git names the
        // occupying worktree in its error ("… already used by worktree at '<path>'").
        if let path = Self.worktreePath(fromCheckoutError: Self.describe(error)) {
            return await openWorktreeSession(path: path, folderId: nil, root: root)
        }
        return nil
    }

    /// Open (registering if needed) the folder backing the worktree at `path` and
    /// return the intent to start a session there. `folderId` is the already-known
    /// registered folder, if resolution provided one.
    private func openWorktreeSession(path: String, folderId: Int?, root: FolderDetail) async -> BranchSwitchOutcome? {
        if let folderId, let target = allFolders.first(where: { $0.id == folderId }) {
            _ = try? await client.openFolder(path: target.path)
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: folderId)
        }
        guard let detail = try? await client.openWorktreeFolder(path: path, sourceFolderId: root.id) else {
            return nil
        }
        NotificationCenter.default.post(name: .foldersDidChange, object: nil)
        return .openSession(folderId: detail.id)
    }

    /// Extract the worktree path from git's "already used by worktree at '<path>'"
    /// checkout error, or nil when the message isn't that collision (so a genuine
    /// failure like a dirty tree isn't mistaken for one).
    static func worktreePath(fromCheckoutError message: String) -> String? {
        guard message.contains("already used by worktree") else { return nil }
        guard let start = message.range(of: "at '")?.upperBound,
              let end = message[start...].firstIndex(of: "'") else { return nil }
        let path = String(message[start..<end])
        return path.isEmpty ? nil : path
    }

    /// Create `branch` (off `startPoint`; nil = current HEAD) and check it out.
    func createBranch(_ branch: String, from startPoint: String?) async -> Bool {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = folder?.path, !name.isEmpty else { return false }
        do {
            try await client.gitNewBranch(path: path, branchName: name, startPoint: startPoint)
            currentBranch = name
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    // MARK: - Attachments

    /// Append newly-prepared images, enforcing both a count cap and an aggregate
    /// byte budget (so the base64 prompt payload stays under the server's body
    /// limit), and surfacing a notice if any were dropped.
    func addAttachments(_ newAttachments: [Attachment]) {
        guard !newAttachments.isEmpty else { return }
        var currentBytes = attachments.reduce(0) { $0 + $1.byteCount }
        var droppedForCount = false
        var droppedForSize = false
        for attachment in newAttachments {
            if attachments.count >= AttachmentPrep.maxCount {
                droppedForCount = true
                break
            }
            if currentBytes + attachment.byteCount > AttachmentPrep.maxTotalBytes {
                droppedForSize = true
                continue
            }
            attachments.append(attachment)
            currentBytes += attachment.byteCount
        }
        if droppedForCount {
            notice = "You can attach up to \(AttachmentPrep.maxCount) images."
        } else if droppedForSize {
            notice = "Some images were too large to attach."
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Send

    /// Send the composer's draft — or, with `overrideText`, a prompt the app itself
    /// generated (today: the revision notes from a plan-approval "request changes",
    /// which Grok expects as a follow-up turn). An override never touches the
    /// composer's draft or attachments, so a message the user was typing survives;
    /// a rejected send still restores the text into the composer so it isn't lost.
    func send(overrideText: String? = nil) {
        let text = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = overrideText == nil ? attachments : []
        guard (!text.isEmpty || !sending.isEmpty), !isInFlight else { return }
        // Identity comes from the loaded summary (existing conversation) or the
        // new-task request; without either the screen isn't ready to send.
        guard summary != nil || newRequest != nil else { return }
        // A draft (no linked summary yet) needs a folder + agent before it can
        // connect; lock the pickers the moment its first send begins.
        if summary == nil {
            guard folder != nil, selectedAgent != nil else {
                notice = "Pick a folder and agent first."
                return
            }
            hasStartedFirstSend = true
        }

        // If the previous reply finished streaming but never reconciled into the
        // transcript (slow server persistence, or refreshAfterTurn still retrying),
        // fold it into `turns` before we reuse the `liveTurn` slot — otherwise this
        // send would drop that reply from view until the next reconcile.
        if let prior = liveTurn, !prior.isStreaming, !prior.isEmpty {
            promoteUnreconciled(prior)
        }

        // 1) Optimistic user turn (text first, then images) + clear the composer.
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: sending.map { $0.optimisticBlock })
        let userTurn = MessageTurn(
            id: "pending-\(UUID().uuidString)",
            role: .user,
            blocks: blocks,
            timestamp: Date()
        )
        pendingUserTurns.append(userTurn)
        if overrideText == nil {
            draft = ""
            attachments = []
        }

        // 2) Live assistant placeholder.
        let live = LiveTurn()
        liveTurn = live
        // A locally-sent turn: the reply streams into this placeholder and the
        // prompt lives in `pendingUserTurns`, so `turns` carries no persisted
        // in-flight reply to suppress. Clearing here is also the single point that
        // un-sticks a stale reattach flag once the user sends again.
        liveTurnFromReattach = false
        sendState = .connecting
        notice = nil
        // The user's own send always re-pins, even if they'd scrolled up.
        requestStickToBottom()

        // 3) Run the network + streaming flow.
        sendTask?.cancel()
        let userTurnID = userTurn.id
        sendTask = Task { [weak self] in
            await self?.runSend(text: text, attachments: sending, live: live, userTurnID: userTurnID)
        }
    }

    private func runSend(text: String, attachments sending: [Attachment], live: LiveTurn, userTurnID: String) async {
        let clientMessageID = UUID().uuidString
        do {
            // For a brand-new draft, create the conversation row server-side BEFORE
            // prompting so every client (desktop / web) sees it immediately. No-op
            // for an existing or already-created conversation.
            try await ensureConversationCreated(firstPromptText: text)

            // Resolve a connection (reuse → existing live conn → fresh spawn).
            let conn = try await resolveConnection()
            connectionID = conn

            // Open the event stream and wait until it is ready + attached.
            try await openStream(connectionID: conn, live: live)
            guard !Task.isCancelled else { return }

            isTurnActive = true
            if case .connecting = sendState { sendState = .thinking }

            // Fire the prompt; the reply arrives over the stream. Once this
            // returns, the server has accepted the turn — past this point a
            // failure is a *stream* failure (handled by the consumer loop), not a
            // send failure, so the optimistic turn must stay on screen.
            try await sendPrompt(conn: conn, text: text, attachments: sending, clientMessageID: clientMessageID)
            // Prompt accepted — the created conversation is now legitimately in use,
            // so it must not be rolled back by a later stream failure.
            draftCreatedConversationID = nil
        } catch let error as APIError where error.isStaleConnection {
            // Stale connection → drop it and retry once with a fresh spawn.
            connectionID = nil
            await retrySendOnce(text: text, attachments: sending, live: live, clientMessageID: clientMessageID, userTurnID: userTurnID)
        } catch APIError.turnInProgress {
            notice = "A turn is already running on this session. Try again in a moment."
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text, restoringAttachments: sending)
        } catch is CancellationError {
            // Cancelled by the user / view teardown — handled in cancel().
        } catch {
            // Reaching here means the prompt was never accepted (resolve/attach/
            // prompt threw), so the optimistic user turn never made it to the
            // server. Roll it back and surface why, instead of stranding a
            // phantom "sent" message in the transcript.
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text, restoringAttachments: sending)
            notice = Self.describe(error)
        }
    }

    private func retrySendOnce(text: String, attachments sending: [Attachment], live: LiveTurn, clientMessageID: String, userTurnID: String) async {
        do {
            closeStream()
            let prefs = preferredSelectors
            let conn = try await client.connect(
                agentType: agentTypeForUI,
                workingDir: folder?.path,
                sessionId: summary?.externalId,
                preferredModeId: prefs.modeId,
                preferredConfigValues: prefs.configValues
            )
            connectionID = conn
            try await openStream(connectionID: conn, live: live)
            guard !Task.isCancelled else { return }
            isTurnActive = true
            if case .connecting = sendState { sendState = .thinking }
            try await sendPrompt(conn: conn, text: text, attachments: sending, clientMessageID: clientMessageID)
            draftCreatedConversationID = nil
        } catch is CancellationError {
            // no-op
        } catch APIError.turnInProgress {
            notice = "A turn is already running on this session. Try again in a moment."
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text, restoringAttachments: sending)
        } catch {
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text, restoringAttachments: sending)
            notice = Self.describe(error)
        }
    }

    /// The user's last-used mode/config for the active agent, sent on every
    /// `connect` so a fresh session starts with their saved selections (mirrors
    /// the web client). Empty/nil values are omitted by the request encoder.
    private var preferredSelectors: SelectorPrefs {
        SelectorPrefsStore.prefs(for: agentTypeForUI)
    }

    private func resolveConnection() async throws -> String {
        if let existing = connectionID { return existing }
        // Only a linked conversation can have a server-side connection to find;
        // a new task always spawns fresh (no sessionId → a brand-new session).
        if let id = conversationID,
           let found = try await client.findConnection(
               conversationId: id,
               sessionId: summary?.externalId,
               agentType: agentTypeForUI
           )?.connectionId {
            return found
        }
        let prefs = preferredSelectors
        return try await client.connect(
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionId: summary?.externalId,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
    }

    /// Resolve a live chat connection for out-of-band actions — currently applying
    /// agent mode/config from the options sheet. Unlike the send path, this does
    /// NOT trust a cached `connectionID`: it validates liveness via `findConnection`
    /// (which returns the conversation's bound connection or nil) and only spawns a
    /// fresh one when none is live, so a mode/config change can't be sent to a
    /// connection the server has since garbage-collected. The result is cached so
    /// the next send reuses the same connection.
    func resolveConnectionForOptions() async throws -> String {
        if let id = conversationID,
           let found = try await client.findConnection(
               conversationId: id,
               sessionId: summary?.externalId,
               agentType: agentTypeForUI
           )?.connectionId {
            connectionID = found
            return found
        }
        let prefs = preferredSelectors
        let conn = try await client.connect(
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionId: summary?.externalId,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
        connectionID = conn
        return conn
    }

    private func sendPrompt(conn: String, text: String, attachments sending: [Attachment], clientMessageID: String) async throws {
        // Text first, then images — matches the web client's block order.
        var blocks: [PromptInputBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: sending.map { $0.promptInputBlock })
        // A new task sends a nil conversationId + the target folderId; the
        // server creates the conversation and announces it via
        // `conversation_linked` on the stream.
        try await client.prompt(
            connectionId: conn,
            blocks: blocks,
            folderId: summary?.folderId ?? folder?.id,
            conversationId: conversationID,
            clientMessageId: clientMessageID
        )
    }

    /// Create the server-side conversation row up front for a brand-new draft's
    /// first send (mirrors codeg web). This is what makes the new session visible
    /// to *other* clients immediately: `create_conversation` broadcasts a
    /// `conversation_upsert` to every connected client, whereas prompting with a
    /// nil `conversationId` creates the row implicitly and announces it only on
    /// this client's own stream — so the desktop never learns of it.
    ///
    /// No-op once a conversation exists (existing session, or a retry after the
    /// row was already created). On failure it throws into `runSend`'s `catch`,
    /// which rolls the optimistic send back.
    private func ensureConversationCreated(firstPromptText text: String) async throws {
        guard conversationID == nil, let folderId = folder?.id, let agent = selectedAgent else { return }
        let id = try await client.createConversation(
            folderId: folderId,
            agentType: agent,
            title: Self.draftTitle(from: text)
        )
        conversationID = id
        draftCreatedConversationID = id
        currentBranch = folder?.gitBranch
        // Refresh this app's own session list so the new row shows there too.
        notifyConversationsChanged()
        // Fetch identity (title / status / external id) in the background so the
        // nav-bar title + actions menu light up — without blocking the prompt's
        // first token on an extra round-trip.
        Task { [weak self] in
            guard let self,
                  let detail = try? await self.client.conversationDetail(id: id),
                  self.conversationID == id else { return }
            self.summary = detail.summary
            self.sessionStats = detail.sessionStats ?? self.sessionStats
            self.insertModel.agentType = detail.summary.agentType
        }
    }

    /// A title for a freshly created conversation, derived from the first prompt
    /// (first non-empty line, capped to 80 chars) — mirrors the web client. nil →
    /// the server titles it later from the session.
    private static func draftTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(80))
    }

    // MARK: - Stream lifecycle

    /// Resolved by the consumer loop the moment the socket reports `.ready`, so
    /// `openStream` can return only after the stream is attached. Single-shot.
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Opens a fresh `EventStream`, spawns the single consumer loop, and suspends
    /// until that loop has seen `.ready` and attached. There is exactly one
    /// iterator over `frames` — the consumer loop — so frames are never dropped.
    private func openStream(connectionID conn: String, live: LiveTurn) async throws {
        closeStream()
        streamReconnects = 0   // fresh send → fresh reconnect budget
        streamGeneration &+= 1
        let generation = streamGeneration
        let newStream = EventStream(baseURL: client.baseURL, token: client.token)
        stream = newStream
        newStream.start()

        consumerTask = Task { [weak self] in
            await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation)
        }

        // Safety net for a hung socket. A healthy server always answers `attach`
        // immediately — either a snapshot/replay frame (success) or a detached
        // frame (connection gone). If neither arrives within the window, FAIL the
        // send rather than prompting without a confirmed subscription: a blind
        // `acp_prompt` could reach the server before the attach registers, so the
        // reply's first events would be delivered to no subscriber and lost.
        let readyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            self?.resumeReady(throwing: APIError.transport(
                "the live connection timed out — check the server and try again"))
        }
        defer { readyTimeout.cancel() }

        // Wait for the consumer loop to signal readiness (resolved once the attach
        // is confirmed by the server's snapshot/replay frame).
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if readyContinuation != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readyContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeReady(throwing: CancellationError()) }
        }
    }

    /// The sole consumer of `stream.frames`. Attaches on `.ready`, maps `.event`
    /// frames onto the live turn, and finalizes on terminal frames. A superseded
    /// consumer (its `generation` no longer current) ignores its terminal frames
    /// so it can't end a turn that a newer stream now owns.
    private func consume(stream: EventStream, connectionID conn: String, live: LiveTurn, generation: Int) async {
        for await frame in stream.frames {
            if Task.isCancelled { return }
            let isCurrent = generation == streamGeneration
            switch frame {
            case .ready:
                // Send attach, but do NOT release openStream yet: wait for the
                // server to confirm the subscription (snapshot/replay) before the
                // prompt is fired. Otherwise acp_prompt (a separate HTTP request)
                // can reach the server before the WS attach is registered, and the
                // first streamed events would be delivered to no subscriber.
                stream.attach(subscriptionId: subscriptionID, connectionId: conn)
            case .snapshot(let snap):
                // Attach confirmed — a healthy socket. Reset the reconnect budget
                // and (for the initial connect) release the waiting send.
                streamReconnects = 0
                // A mid-turn RECONNECT can drop the socket exactly as a
                // `permission_request` / `question_request` arrives — losing that
                // live event. The fresh snapshot still carries the pending card, so
                // restore it; otherwise an ExitPlanMode / permission prompt is
                // silently lost across the reconnect and the reply "looks finished"
                // with no way to approve. Mirrors `consumeReattach` + the web client.
                // Skipped during the INITIAL attach handshake (readyContinuation set)
                // — that snapshot is the pre-prompt state and carries no live card.
                if isCurrent, readyContinuation == nil, isTurnActive { restorePending(from: snap) }
                if isCurrent { resumeReady(throwing: nil) }
            case .replay:
                streamReconnects = 0
                if isCurrent { resumeReady(throwing: nil) }
            case .pong:
                break
            case .event(let envelope):
                if isCurrent { handle(event: envelope.event, live: live) }
            case .detached(let reason):
                guard isCurrent else { return }
                // During the attach handshake (before the prompt is accepted),
                // surface the detach so `runSend` retries with a fresh connection.
                if readyContinuation != nil {
                    let error: APIError = reason == "connection_gone"
                        ? .streamGone
                        : .transport(reason.isEmpty ? "The session detached." : reason)
                    resumeReady(throwing: error)
                    return
                }
                // Mid-turn detach. `connection_gone` is terminal (the connection
                // was GC'd) — reconcile rather than blindly error, since the turn
                // may have finished. `lagged` / `server_shutdown` are transient:
                // re-attach silently, matching the web client.
                guard isTurnActive else { return }
                if reason == "connection_gone" {
                    Task { [weak self] in await self?.reconcileOrFail(live: live, reason: reason) }
                } else {
                    reconnectStream(into: live, connectionID: conn, reason: reason)
                }
                return
            case .closed(let reason):
                guard isCurrent else { return }
                // Socket dropped during the attach handshake: fail the send (nothing
                // streamed yet) so `runSend` can retry from a clean connection.
                if readyContinuation != nil {
                    resumeReady(throwing: APIError.transport(reason ?? "The event stream closed unexpectedly."))
                    return
                }
                // Past the handshake a turn is streaming. The ACP connection
                // outlives the WebSocket, so a dropped socket is a transport blip:
                // re-attach silently instead of erroring (web parity).
                if isTurnActive { reconnectStream(into: live, connectionID: conn, reason: reason) }
                return
            }
        }
    }

    /// Resolve the pending `openStream` suspension exactly once.
    private func resumeReady(throwing error: Error?) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    // MARK: - Reattach (open a session whose turn is already in-flight)

    /// After loading an existing conversation, attach to its live connection — if
    /// one exists and a turn is in-flight (or a card is pending) — so the reply
    /// streams and any pending permission/question surfaces, all WITHOUT sending.
    /// This is the cross-client / app-relaunch path: a turn started in codeg web
    /// (or left blocked) becomes interactive on open. Idle connections are dropped.
    ///
    /// Additive: it does not touch the send flow. The moment the user sends,
    /// `openStream` supersedes this stream (a generation bump ends this consumer).
    func reattachIfLive(serverSaysLive: Bool = false) async {
        guard let id = conversationID, summary != nil else { return }
        // Nothing to do if we're already streaming locally, or for a finished session.
        guard liveTurn == nil, !isInFlight, stream == nil else { return }
        if summary?.status == .completed || summary?.status == .cancelled { return }

        // Discover the live ACP connection. When the server reported a turn in
        // flight (`serverSaysLive`), a single discovery miss is almost always a
        // transient blip or a bind-lag race (the connection links to the
        // conversation a beat after the prompt) rather than a finished turn — so
        // retry a few times with a short backoff before giving up. Without that, a
        // lone miss leaves the user on a static transcript for the screen's
        // lifetime (the web never misses because it tracks connections
        // continuously; this is the poll-era stand-in). When the server does NOT
        // claim a live turn, one best-effort probe is enough.
        let attempts = serverSaysLive ? 4 : 1
        var conn: String?
        for attempt in 0..<attempts {
            // Bail if a send (or another reattach) started while we awaited.
            guard liveTurn == nil, !isInFlight, stream == nil else { return }
            if let found = try? await client.findConnection(
                conversationId: id,
                sessionId: summary?.externalId,
                agentType: agentTypeForUI
            )?.connectionId {
                conn = found
                break
            }
            // Back off before the next attempt (no sleep after the last one).
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }

        guard let conn else {
            // The server claimed a live turn but no connection ever surfaced — it
            // most likely finished during load, leaving our fetched transcript a
            // beat stale. Reconcile once so the final reply isn't missing.
            if serverSaysLive { await reconcileAfterMissedLive() }
            return
        }

        // Re-check: a send may have started while we awaited.
        guard liveTurn == nil, !isInFlight, stream == nil else { return }

        connectionID = conn
        closeStream()
        streamGeneration &+= 1
        let generation = streamGeneration
        let newStream = EventStream(baseURL: client.baseURL, token: client.token)
        stream = newStream
        newStream.start()
        consumerTask = Task { [weak self] in
            await self?.consumeReattach(stream: newStream, connectionID: conn, generation: generation, serverSaysLive: serverSaysLive)
        }
    }

    /// The server reported a live turn at load but we couldn't attach to it (it
    /// finished in the gap, or the connection was momentarily undiscoverable).
    /// Quietly refetch the detail so the transcript shows the final reply rather
    /// than the snapshot we loaded a beat too early. No-op if a turn has since
    /// started locally — that path owns the transcript.
    private func reconcileAfterMissedLive() async {
        guard let id = conversationID, liveTurn == nil, !isInFlight, stream == nil else { return }
        guard let detail = try? await client.conversationDetail(id: id) else { return }
        guard liveTurn == nil, !isInFlight, stream == nil else { return }
        summary = detail.summary
        turns = detail.turns
        sessionStats = detail.sessionStats ?? sessionStats
        requestStickToBottom()
    }

    /// Consumer for the reattach stream. Unlike `consume`, it has no `openStream`
    /// continuation to release and it BUILDS the live turn from the attach snapshot
    /// rather than being handed one. If the snapshot shows nothing in flight, it
    /// closes the stream (idle connection — leave it alone).
    private func consumeReattach(stream: EventStream, connectionID conn: String, generation: Int, serverSaysLive: Bool = false) async {
        var live: LiveTurn?
        for await frame in stream.frames {
            if Task.isCancelled { return }
            // A send (or another reattach) superseded us — let go; the new stream owns the turn.
            guard generation == streamGeneration else { return }
            switch frame {
            case .ready:
                stream.attach(subscriptionId: subscriptionID, connectionId: conn)
            case .snapshot(let snap):
                // A snapshot means the socket is healthy — reset the reconnect budget.
                streamReconnects = 0
                if let rebuilt = buildLiveTurn(from: snap) {
                    live = rebuilt
                    liveTurn = rebuilt
                    // This live turn is the snapshot's complete in-flight reply;
                    // the transcript must hide any partial copy the agent has
                    // begun persisting into `turns` so the reply isn't doubled.
                    liveTurnFromReattach = true
                    isTurnActive = true
                    restorePending(from: snap)
                    sendState = .thinking
                    requestStickToBottom()
                } else {
                    // Idle connection: nothing in flight. Release it.
                    closeStream()
                    connectionID = nil
                    // If the server had claimed a live turn at load, it finished
                    // between the detail fetch and this snapshot — reconcile so the
                    // final reply isn't missing from the (now stale) transcript.
                    if serverSaysLive { await reconcileAfterMissedLive() }
                    return
                }
            case .replay(let events):
                if let live { for env in events { handle(event: env.event, live: live) } }
            case .pong:
                break
            case .event(let envelope):
                // The attach snapshot always precedes events, so `live` is set by now.
                if let live { handle(event: envelope.event, live: live) }
            case .detached(let reason):
                // Pre-snapshot drops have nothing on screen — stay quiet. Once a
                // turn is live, recover transient detaches silently (web parity);
                // only `connection_gone` reconciles/fails.
                guard isTurnActive, let live else { return }
                if reason == "connection_gone" {
                    Task { [weak self] in await self?.reconcileOrFail(live: live, reason: reason) }
                } else {
                    reconnectStream(into: live, connectionID: conn, reason: reason, reattach: true)
                }
                return
            case .closed(let reason):
                // A socket drop while a turn is live is a transport blip — re-attach
                // silently. (Before the snapshot there's nothing to recover.)
                if isTurnActive, let live {
                    reconnectStream(into: live, connectionID: conn, reason: reason, reattach: true)
                }
                return
            }
        }
    }

    /// Rebuild an in-flight assistant turn from a reattach snapshot. Returns nil
    /// when the connection is idle (no live message, no plan, no pending card, and
    /// not actively prompting).
    private func buildLiveTurn(from snap: LiveSessionSnapshot) -> LiveTurn? {
        let blocks = snap.liveMessage?.content ?? []
        let hasPending = snap.pendingPermission != nil || snap.pendingQuestion != nil
            || snap.pendingPlanApproval != nil
        guard !blocks.isEmpty || hasPending || snap.status == .prompting else { return nil }

        let live = LiveTurn()
        let toolsById = Dictionary((snap.activeToolCalls ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for block in blocks {
            switch block {
            case .text(let t): live.appendText(t)
            case .thinking(let t): live.appendThinking(t)
            case .toolCallRef(let toolId):
                guard let st = toolsById[toolId] else { break }
                live.upsertToolCall(
                    id: st.id,
                    title: st.label,
                    kind: st.kind,
                    status: Self.normalizedToolStatus(st.status),
                    rawInput: st.inputPreview,
                    rawOutput: st.outputText,
                    content: st.content,
                    meta: st.meta
                )
            case .plan(let entries):
                live.updatePlan(PlanEntry.list(from: entries))
            case .unknown:
                break
            }
        }
        live.flushAllText()
        return live
    }

    private func restorePending(from snap: LiveSessionSnapshot) {
        if let p = snap.pendingPermission {
            pendingPermission = PendingPermission(requestId: p.requestId, toolCall: p.toolCall, options: p.options)
        }
        if let q = snap.pendingQuestion {
            pendingQuestion = PendingQuestion(questionId: q.questionId, questions: q.questions)
        }
        // Set OR clear: the attach snapshot is the connection's authoritative
        // pending state, so an approval that another client resolved while we were
        // reconnecting must not leave a stale, still-actionable card behind
        // (answering it would post a decision for an approval that no longer
        // exists). The permission/question restores above deliberately keep their
        // existing set-only behavior — changing those is out of scope here.
        if let p = snap.pendingPlanApproval {
            pendingPlanApproval = PendingPlanApproval(
                approvalId: p.approvalId, toolCallId: p.toolCallId, planMarkdown: p.planMarkdown)
        } else {
            pendingPlanApproval = nil
        }
    }

    /// Normalize a snapshot `ToolCallStatus` (which may be PascalCase) to the
    /// lowercase form the live tool card interprets.
    private static func normalizedToolStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "inprogress", "in_progress", "in-progress", "running": return "in_progress"
        case "completed", "done", "success": return "completed"
        case "failed", "error": return "failed"
        case "pending": return "pending"
        default: return raw.lowercased()
        }
    }

    // MARK: - Event → UI mapping

    private func handle(event: AcpEvent, live: LiveTurn) {
        switch event {
        case .contentDelta(let text):
            live.appendText(text)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .thinking(let text):
            live.appendThinking(text)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .toolCall(let id, let title, let kind, let status, let content, let rawInput, let rawOutput, let meta):
            live.upsertToolCall(id: id, title: title, kind: kind, status: status, rawInput: rawInput, rawOutput: rawOutput, content: content, meta: meta)
            sendState = .running(tool: title.isEmpty ? "tool" : title)
            requestScrollToBottom()

        case .toolCallUpdate(let id, let title, let status, let content, let rawInput, let rawOutput, let append, let meta):
            live.updateToolCall(id: id, title: title, status: status, rawInput: rawInput, rawOutput: rawOutput, content: content, append: append, meta: meta)
            if let active = live.activeToolTitle {
                sendState = .running(tool: active)
            } else {
                sendState = .thinking
            }
            requestScrollToBottom()

        case .statusChanged(let status):
            switch status {
            case .connecting: if case .idle = sendState { sendState = .connecting }
            case .prompting: if case .running = sendState {} else { sendState = .thinking }
            case .error:
                failLive(live, message: "The agent connection errored.")
            default:
                break
            }

        case .usageUpdate(let used, let size):
            applyUsage(used: used, size: size)

        case .userMessage:
            // The server echoes our own prompt; we already showed it optimistically.
            break

        case .turnComplete(let stopReason):
            finalize(live: live, stopReason: stopReason)

        case .error(let message, _):
            failLive(live, message: message)

        case .conversationLinked(let linkedID, _):
            adoptLinkedConversation(linkedID)

        case .permissionRequest(let requestId, let toolCall, let options):
            // The agent paused for approval (incl. ExitPlanMode). Surface the card
            // above the compose bar; the turn stays in-flight until it's resolved.
            pendingPermission = PendingPermission(requestId: requestId, toolCall: toolCall, options: options)
            requestScrollToBottom()

        case .permissionResolved(let requestId):
            // Resolved here or by another client — clear the matching card only, so
            // a stale echo can't wipe a freshly-raised one.
            if pendingPermission?.requestId == requestId { pendingPermission = nil }

        case .questionRequest(let questionId, let questions):
            pendingQuestion = PendingQuestion(questionId: questionId, questions: questions)
            requestScrollToBottom()

        case .questionResolved(let questionId):
            if pendingQuestion?.questionId == questionId { pendingQuestion = nil }

        case .planApprovalRequest(let approvalId, let toolCallId, let planMarkdown):
            // Grok finished planning and is blocked until the user decides.
            pendingPlanApproval = PendingPlanApproval(
                approvalId: approvalId, toolCallId: toolCallId, planMarkdown: planMarkdown)
            requestScrollToBottom()

        case .planApprovalResolved(let approvalId):
            if pendingPlanApproval?.approvalId == approvalId { pendingPlanApproval = nil }

        case .planUpdate(let entries):
            live.updatePlan(entries)
            requestScrollToBottom()

        case .sessionStarted, .conversationStatusChanged, .userPromptSent, .unknown:
            break
        }
    }

    /// A new task's first prompt creates the server-side conversation; adopt
    /// its id (and identity summary) without disturbing the in-flight stream.
    private func adoptLinkedConversation(_ id: Int) {
        guard conversationID == nil else { return }
        conversationID = id
        Task { [weak self] in
            guard let self else { return }
            guard let detail = try? await self.client.conversationDetail(id: id),
                  self.conversationID == id else { return }
            // Mid-stream: adopt identity + stats only — the live turn is still
            // rendering and `refreshAfterTurn()` reconciles the transcript.
            self.summary = detail.summary
            self.sessionStats = detail.sessionStats ?? self.sessionStats
            self.insertModel.agentType = detail.summary.agentType
        }
    }

    private func applyUsage(used: UInt64, size: UInt64) {
        let prev = sessionStats
        sessionStats = SessionStats(
            totalUsage: prev?.totalUsage,
            totalTokens: Int(used),
            totalDurationMs: prev?.totalDurationMs ?? 0,
            contextWindowUsedTokens: Int(used),
            contextWindowMaxTokens: size > 0 ? Int(size) : prev?.contextWindowMaxTokens,
            contextWindowUsagePercent: size > 0 ? (Double(used) / Double(size)) * 100 : prev?.contextWindowUsagePercent
        )
    }

    // MARK: - Finalize / fail

    private func finalize(live: LiveTurn, stopReason: String) {
        guard isTurnActive else { return }
        isTurnActive = false
        // Read before clearing: this is the one transition that delivers parked
        // plan-revision notes (every other terminal path drops them).
        let planFollowUp = pendingPlanFollowUp
        clearInteractivePrompts()
        // Publish any pending coalesced text before flipping to the finalized
        // render so the seam is reflow-free (the finalized branch reads the same
        // run text, now complete).
        live.flushAllText()
        live.isStreaming = false
        live.stopReason = stopReason
        sendState = .idle
        completedTurnTick &+= 1
        closeStream()
        requestScrollToBottom()
        // Replace the optimistic + live turns with the authoritative server copy.
        Task { [weak self] in await self?.refreshAfterTurn(reconciling: live) }
        // The keep-planning turn just ended — deliver the revision notes as the
        // follow-up prompt Grok expects (it discards them on the reply itself).
        if let planFollowUp { send(overrideText: planFollowUp) }
    }

    /// Roll back an optimistic send that failed *before the server accepted the
    /// prompt*: tear down the stream, drop the pending user turn and its empty
    /// live placeholder, and restore the user's text so they can retry. The
    /// caller surfaces the reason via `notice`.
    private func discardOptimisticSend(userTurnID: String, live: LiveTurn, restoringDraft text: String, restoringAttachments sent: [Attachment]) {
        isTurnActive = false
        clearInteractivePrompts()
        closeStream()
        pendingUserTurns.removeAll { $0.id == userTurnID }
        if liveTurn === live { liveTurn = nil }
        sendState = .idle
        // If THIS send created the conversation up front (a draft's first send) but
        // the prompt was never accepted, roll that creation back too: delete the
        // empty row (so it doesn't linger in every client's sidebar) and clear the
        // adopted identity, returning the screen to a clean, editable draft.
        if let createdID = draftCreatedConversationID {
            draftCreatedConversationID = nil
            conversationID = nil
            summary = nil
            sessionStats = nil
            Task { [weak self] in
                try? await self?.client.deleteConversation(conversationId: createdID)
                self?.notifyConversationsChanged()
            }
        }
        // The send failed before the server accepted it, so no conversation was
        // created — re-open the draft's agent/folder pickers for an edited retry.
        if conversationID == nil { hasStartedFirstSend = false }
        // Don't clobber a fresh draft the user may have started typing.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        }
        // Restore the staged images too, unless the user has since added new ones.
        if attachments.isEmpty, !sent.isEmpty {
            attachments = sent
        }
        requestScrollToBottom()
    }

    private func failLive(_ live: LiveTurn, message: String?) {
        isTurnActive = false
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if let message { live.errorMessage = message }
        sendState = message.map { .error($0) } ?? .idle
        closeStream()
        // Keep the live turn on screen so the user sees partial output + error;
        // drop the placeholder only if it is completely empty and errorless.
        if live.isEmpty {
            liveTurn = nil
        }
        requestScrollToBottom()
    }

    // MARK: - Stream recovery (transient drops)

    /// Recover a dropped event socket mid-turn by re-opening it and re-attaching
    /// to the SAME server-side ACP connection — which outlives the WebSocket.
    /// Mirrors the web client, whose socket auto-reconnects and re-subscribes its
    /// live streams, so a transient network blip or a server socket recycle no
    /// longer surfaces an error. Backs off between attempts; after
    /// `maxStreamReconnects` consecutive failures with no frames it gives up and
    /// reconciles against the server instead of looping forever.
    ///
    /// `reattach` selects the consumer: the send path (`consume`, feeding the
    /// existing `live`) versus the cross-client reattach path (`consumeReattach`,
    /// which rebuilds `live` from the fresh snapshot).
    private func reconnectStream(into live: LiveTurn, connectionID conn: String, reason: String?, reattach: Bool = false) {
        guard liveTurn === live, isTurnActive else { return }
        streamReconnects += 1
        guard streamReconnects <= Self.maxStreamReconnects else {
            Task { [weak self] in await self?.reconcileOrFail(live: live, reason: reason) }
            return
        }
        let attempt = streamReconnects
        closeStream()              // drop the dead socket (also bumps the generation)
        streamGeneration &+= 1
        let generation = streamGeneration
        // A quiet "connecting" indicator, not a hard error.
        if case .running = sendState {} else { sendState = .connecting }
        reconnectTask = Task { [weak self] in
            // Exponential backoff capped at 8s: 0.5, 1, 2, 4, 8, 8 …
            let delay = min(8.0, 0.5 * pow(2.0, Double(attempt - 1)))
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled,
                  self.liveTurn === live, self.isTurnActive,
                  generation == self.streamGeneration else { return }
            let newStream = EventStream(baseURL: self.client.baseURL, token: self.client.token)
            self.stream = newStream
            newStream.start()
            self.consumerTask = Task { [weak self] in
                if reattach {
                    await self?.consumeReattach(stream: newStream, connectionID: conn, generation: generation)
                } else {
                    await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation)
                }
            }
        }
    }

    /// Recovery's last resort: the socket can't be re-attached (the connection was
    /// GC'd, or reconnects kept failing). The turn may actually have completed
    /// during the outage, so re-fetch the transcript and adopt it silently when the
    /// reply has landed; only when the server still has nothing do we surface an
    /// error — and even then the partial streamed output stays on screen.
    private func reconcileOrFail(live: LiveTurn, reason: String?) async {
        guard liveTurn === live, isTurnActive else { return }
        streamReconnects = 0
        if let id = conversationID,
           let detail = try? await client.conversationDetail(id: id),
           liveTurn === live, isTurnActive {
            summary = detail.summary
            sessionStats = detail.sessionStats ?? sessionStats
            // Adopt only a transcript that genuinely advanced past our pre-turn
            // baseline AND ends with a real reply — never a stale read.
            if detail.turns.count > turns.count, Self.transcriptHasReply(detail.turns) {
                isTurnActive = false
                clearInteractivePrompts()
                turns = detail.turns
                pendingUserTurns.removeAll()
                liveTurn = nil
                sendState = .idle
                closeStream()
                requestScrollToBottom()
                return
            }
        }
        failLive(live, message: "Lost the connection. Your reply may still be running — reopen the session to check.")
    }

    // MARK: - Interactive prompts (permission / question / plan)

    /// Resolve the pending permission (or ExitPlanMode) by selecting an option.
    /// Optimistically clears the card on success; on failure keeps it and returns
    /// `false` so the card can re-enable and show an inline error. The agent then
    /// continues — or stops, for a `reject*` option — over the same stream.
    func respondPermission(optionId: String) async -> Bool {
        guard let pending = pendingPermission, let conn = connectionID else { return false }
        do {
            try await client.respondPermission(connectionId: conn, requestId: pending.requestId, optionId: optionId)
            // Optimistic clear; the stream also echoes `permission_resolved`
            // (idempotent — matched by request id).
            if pendingPermission?.requestId == pending.requestId { pendingPermission = nil }
            requestScrollToBottom()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Answer the pending `ask_user_question`. Optimistic clear on success.
    func answerQuestion(_ answer: QuestionAnswer) async -> Bool {
        guard let pending = pendingQuestion, let conn = connectionID else { return false }
        do {
            try await client.answerQuestion(connectionId: conn, questionId: pending.questionId, answer: answer)
            if pendingQuestion?.questionId == pending.questionId { pendingQuestion = nil }
            requestScrollToBottom()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Dismiss the pending question — the agent proceeds with its own judgment.
    func declineQuestion() async -> Bool {
        await answerQuestion(.dismissed)
    }

    /// Resolve Grok's blocked `exit_plan_mode`. Optimistic clear on success.
    ///
    /// "Request changes" needs one extra step: Grok DISCARDS the reply's `feedback`
    /// on the keep-planning path (only approve/abandon consume it), and its own TUI
    /// instead delivers the revision notes as a follow-up user turn. Mirror that —
    /// otherwise the notes vanish and Grok re-presents the same plan. The
    /// keep-planning turn is usually still winding down at this point, so the
    /// follow-up is parked and flushed when the turn completes.
    func answerPlanApproval(decision: PlanApprovalDecision, feedback: String?) async -> Bool {
        guard let pending = pendingPlanApproval, let conn = connectionID else { return false }
        let notes = (feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.answerPlanApproval(connectionId: conn, approvalId: pending.approvalId,
                                                decision: decision, feedback: notes.isEmpty ? nil : notes)
            if pendingPlanApproval?.approvalId == pending.approvalId { pendingPlanApproval = nil }
            if decision == .requestChanges, !notes.isEmpty {
                // Park the notes for THIS turn's completion — `finalize` picks them
                // up. If the keep-planning turn already ended, send them now.
                if isInFlight { pendingPlanFollowUp = notes } else { send(overrideText: notes) }
            }
            requestScrollToBottom()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// A blocked permission/question/plan-approval can't outlive its turn: clear
    /// any pending card when the turn finalizes, fails, or is cancelled.
    ///
    /// Parked plan-revision notes are dropped here too — they are meaningful only
    /// as the immediate follow-up to the keep-planning turn that produced them. A
    /// turn that failed or was cancelled never gets that follow-up, and leaving
    /// the notes parked would let a LATER, unrelated turn's completion send them.
    /// (`finalize` — the one path that legitimately delivers them — reads them
    /// before calling this.)
    private func clearInteractivePrompts() {
        pendingPermission = nil
        pendingQuestion = nil
        pendingPlanApproval = nil
        pendingPlanFollowUp = nil
    }

    /// After a successful turn, re-fetch the persisted transcript and splice it
    /// in, dropping the optimistic user turns and the live placeholder so nothing
    /// renders twice.
    ///
    /// The server emits `turn_complete` a beat *before* the assistant reply is
    /// queryable, so an immediate `conversationDetail` can come back without the
    /// new reply (only the user turn persisted, or the assistant turn present but
    /// still empty). Adopting that blindly would replace the just-streamed reply
    /// with an empty "No content" turn — the bug this guards against. So we only
    /// retire the finalized live turn once the fetched transcript actually carries
    /// the reply; until then the live turn (now pulse-free) stays on screen, and
    /// we retry a few times with a short backoff. If it never reconciles, the live
    /// turn simply remains — the content is preserved and a later full load
    /// reconciles it.
    private func refreshAfterTurn(reconciling live: LiveTurn) async {
        // A new task that never got linked keeps its locally rendered turns.
        guard let id = conversationID else { return }
        // Whether the finished live turn has content worth preserving. If it was
        // empty (e.g. a no-op turn), there's nothing to protect — adopt whatever
        // the server returns on the first successful fetch.
        let mustPreserveReply = !live.isEmpty
        // Pre-turn baseline. A fetched transcript is only "ours" once it has grown
        // past this — otherwise a stale read that still ends with the *previous*
        // turn's assistant reply would satisfy `transcriptHasReply` and we'd adopt
        // it, dropping the reply we just streamed. `turns` isn't mutated elsewhere
        // between finalize and this reconcile.
        let baselineCount = turns.count

        for attempt in 0..<5 {
            // If the user started another turn while we were reconciling, that
            // newer turn now owns turns/pendingUserTurns/liveTurn; bail so we
            // don't wipe its in-flight state (its own finalize reconciles later).
            guard liveTurn === live else { return }
            do {
                let detail = try await client.conversationDetail(id: id)
                // Re-check after the await — a new turn may have begun during it.
                guard liveTurn === live else { return }
                // Identity/stats are always safe to adopt, even before the reply
                // is queryable, so the header stays fresh while we wait.
                summary = detail.summary
                sessionStats = detail.sessionStats ?? sessionStats

                // Adopt only once the transcript has genuinely advanced for THIS
                // turn: it must have grown past the baseline (so a stale read that
                // merely ends with an older reply can't masquerade as ours) and —
                // when there's a streamed reply to protect — end with a non-empty
                // assistant turn.
                let advanced = detail.turns.count > baselineCount
                if advanced, !mustPreserveReply || Self.transcriptHasReply(detail.turns) {
                    turns = detail.turns
                    pendingUserTurns.removeAll()
                    liveTurn = nil
                    requestScrollToBottom()
                    return
                }
                // Not reconciled for this turn yet — keep the finalized live turn
                // visible and try again shortly.
            } catch {
                // Re-fetch failed: keep the live turn (now finalized, no pulse) so
                // the user still sees the reply, then retry.
            }
            // Don't sleep after the final attempt.
            if attempt < 4 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Gave up reconciling (the server hasn't persisted the reply within the
        // retry window). Fold the finalized reply — and its optimistic user turn —
        // into the authoritative `turns` so it survives a subsequent send instead
        // of living only in the single `liveTurn` slot; a later reconcile or full
        // load replaces it with the server's copy.
        promoteUnreconciled(live)
    }

    /// Fold a finalized-but-unreconciled live reply (plus the optimistic user
    /// turn(s) still awaiting persistence) into `turns`, so the reply is never
    /// dropped from view when the `liveTurn` slot is reused by the next send. The
    /// synthesized turns are transient: the next successful `refreshAfterTurn` /
    /// `load` overwrites `turns` wholesale with the server's authoritative copy.
    private func promoteUnreconciled(_ live: LiveTurn) {
        // Only act while this is still the current live turn — if a newer turn has
        // taken over, it already owns (and preserved) the prior state.
        guard liveTurn === live else { return }
        turns.append(contentsOf: pendingUserTurns)
        pendingUserTurns.removeAll()
        // Only fold in an assistant turn that actually has renderable content. A
        // finalized turn can be non-empty *solely* because of an inline error /
        // "Cancelled." message (which `snapshotAsMessageTurn` can't represent as a
        // persisted block, since ContentBlock has no error case) — appending its
        // zero-block snapshot would render as "No content". Such a transient error
        // placeholder is simply dropped on the next send; the user turn is kept.
        let snapshot = live.snapshotAsMessageTurn()
        if !snapshot.blocks.isEmpty {
            turns.append(snapshot)
        }
        liveTurn = nil
        requestScrollToBottom()
    }

    /// True when the latest persisted turn is an assistant reply that actually
    /// carries renderable content — the signal that the server has committed the
    /// reply we just streamed (vs. only the user turn, or an empty placeholder).
    private static func transcriptHasReply(_ turns: [MessageTurn]) -> Bool {
        guard let last = turns.last, last.role == .assistant else { return false }
        return last.blocks.contains { block in
            switch block {
            case .text(let t), .thinking(let t):
                return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .toolUse, .toolResult, .unknown:
                return true
            case .imageGeneration(let prompt, let image):
                return image != nil || !(prompt ?? "").isEmpty
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        guard let live = liveTurn else { return }
        let conn = connectionID
        isTurnActive = false
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if live.isEmpty {
            live.errorMessage = "Cancelled."
        }
        sendState = .idle
        sendTask?.cancel()
        consumerTask?.cancel()
        closeStream()
        requestScrollToBottom()
        if let conn {
            Task { [weak self] in
                try? await self?.client.cancel(connectionId: conn)
            }
        }
    }

    private func closeStream() {
        // Supersede the current consumer so its imminent `.closed`/`.detached`
        // frame is ignored (it must not end a turn we are deliberately closing).
        streamGeneration &+= 1
        resumeReady(throwing: CancellationError())
        // Drop any pending silent reconnect — a deliberate close ends recovery.
        reconnectTask?.cancel()
        reconnectTask = nil
        stream?.detach(subscriptionId: subscriptionID)
        stream?.close()
        stream = nil
    }

    /// Tear down all live work — call from `.onDisappear` / deinit paths.
    func teardown() {
        sendTask?.cancel()
        sendTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        agentOptions.teardown()
        insertModel.teardown()
        closeStream()
    }

    // MARK: - Scroll

    private func requestScrollToBottom() {
        scrollTick &+= 1
    }

    /// Force the transcript to re-pin to the bottom even if the user had scrolled
    /// up (their own send / initial load).
    private func requestStickToBottom() {
        stickTick &+= 1
    }

    /// The transcript reports its bottom-proximity here as the user scrolls, so the
    /// floating "jump to latest" button can appear/disappear.
    func setPinnedToBottom(_ pinned: Bool) {
        if isPinnedToBottom != pinned { isPinnedToBottom = pinned }
    }

    /// The user tapped the floating "jump to latest" button.
    func userTappedScrollToBottom() {
        isPinnedToBottom = true
        requestStickToBottom()
    }

    // MARK: - Conversation actions (nav-bar "…" menu)

    /// Whether there's a real, server-linked conversation to act on (gates the
    /// actions menu; a brand-new unsent draft has none yet).
    var canManageConversation: Bool { conversationID != nil && summary != nil }

    /// Pinned state for the menu's Pin/Unpin label.
    var isPinned: Bool { summary?.isPinned ?? false }

    /// Current lifecycle status (for the status submenu's checkmark).
    var currentStatus: ConversationStatus? { summary?.status }

    /// Rename the conversation. Optimistically updates the title (so the nav
    /// title and details sheet reflect it immediately), reverting on failure.
    func rename(to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = conversationID, !trimmed.isEmpty, trimmed != summary?.title else { return }
        let previous = summary?.title
        summary?.title = trimmed
        do {
            try await client.renameConversation(conversationId: id, title: trimmed)
            notifyConversationsChanged()
        } catch {
            summary?.title = previous
            notice = Self.describe(error)
        }
    }

    /// Pin or unpin. Optimistically flips `pinnedAt`, reverting on failure.
    func togglePin() async {
        guard let id = conversationID else { return }
        userToggleTick &+= 1
        let next = !isPinned
        let previous = summary?.pinnedAt
        summary?.pinnedAt = next ? (previous ?? Date()) : nil
        do {
            try await client.setPinned(conversationId: id, pinned: next)
            notifyConversationsChanged()
        } catch {
            summary?.pinnedAt = previous
            notice = Self.describe(error)
        }
    }

    /// Change lifecycle status. Optimistically updates, reverting on failure.
    func setStatus(_ status: ConversationStatus) async {
        guard let id = conversationID, summary?.status != status else { return }
        userToggleTick &+= 1
        let previous = summary?.status
        summary?.status = status
        do {
            try await client.updateStatus(conversationId: id, status: status)
            notifyConversationsChanged()
        } catch {
            summary?.status = previous ?? status
            notice = Self.describe(error)
        }
    }

    /// Permanently delete the conversation. Returns `true` on success so the
    /// view can pop back to the list; on failure surfaces a notice and stays.
    func deleteConversation() async -> Bool {
        guard let id = conversationID else { return false }
        do {
            try await client.deleteConversation(conversationId: id)
            notifyConversationsChanged()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Tell the (separate) session-list view model to refetch after a mutation,
    /// so it doesn't show a stale title/status or a still-tappable deleted row.
    private func notifyConversationsChanged() {
        NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}
