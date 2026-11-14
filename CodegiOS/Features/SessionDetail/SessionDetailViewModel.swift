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
    /// Which replies are folded in the activity timeline. A send folds every
    /// reply above it; see ``ReplyFoldStore``.
    let replyFolds = ReplyFoldStore()

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

    // MARK: Transcript window
    //
    // `turns` is not necessarily the whole transcript: from 0.24 the server can
    // serialize a *window* of it, and a long session's full history reaches tens
    // of megabytes — which this screen used to download in full on open, again on
    // every reconcile attempt after a turn, and again just to read the title.
    //
    // The invariant that makes this cheap to graft onto the existing code:
    // **`turns` is always the suffix `full[window.offset...]`**. Every refresh
    // therefore anchors at `fromIndex: window.offset` rather than re-requesting a
    // tail, so the fetched region is exactly the region held — and comparisons
    // against it keep meaning what they meant when the whole transcript was
    // loaded. (Refreshing with `tailTurns` instead would silently cap the fetched
    // count, and "did the transcript grow?" would go permanently false on any
    // session longer than the window.)

    /// Where `turns` sits in the full transcript, or `nil` when it *is* the full
    /// transcript — a server that predates windowing, or a fetch made before the
    /// first windowed response landed.
    private(set) var window: TranscriptWindow?
    /// A page of older history is being fetched (drives the transcript's spinner).
    private(set) var loadingOlderTurns = false

    /// The user turn that opened the round the server says is running right now.
    /// Unlike the window this describes the FULL transcript, but it is adopted with
    /// `turns` all the same: it scopes them, and a scope that outlived the turns it
    /// scopes would put a spinner on the wrong round. `nil` whenever the server
    /// reports nothing in flight.
    private(set) var inFlightUserTurnId: String?

    /// Turns to request on the first fetch of a session. Matches the web client's
    /// tail; comfortably more than the transcript renders on open (its own view
    /// window is 50), so scrolling up is instant for a while before it pages.
    private static let tailTurns = 120
    /// Turns per page when scrolling up into older history.
    private static let olderTurnsPage = 120
    /// Window for the fetches that only read identity/stats and never touch
    /// `turns`. Those fields describe the FULL transcript whatever the window is,
    /// so ask for the smallest legal one. (The server still walks back to a round
    /// boundary, so this returns a handful of turns, not one — they're discarded.)
    private static let identityTurns = 1

    /// Global index one past the last loaded turn — the coordinate a fetched
    /// response's `globalEnd` is compared against to decide whether the server's
    /// transcript has advanced past what is held. Equals `turns.count` exactly
    /// when nothing is windowed.
    private var loadedEnd: Int { (window?.offset ?? 0) + turns.count }

    /// Older history exists above what is loaded, so the transcript should offer
    /// to page up. False on a legacy server (everything is already loaded).
    var hasOlderTurns: Bool { window?.hasOlder ?? false }

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

    // MARK: - pi project trust

    /// Last project-trust probe, PAIRED with the directory it was made for.
    ///
    /// The pair is the point: the backend answers about a canonical path that can
    /// differ from the one asked about, and the draft's folder is editable, so a
    /// slow reply must never be read as describing whatever folder is selected
    /// when it lands — that would show one project's files while writing the
    /// decision to another.
    private(set) var piTrust: (requestedFor: String, state: PiProjectTrustState)?
    /// Bumped whenever the probe's inputs change, retiring anything in flight.
    private var piTrustGeneration = 0
    /// Dismissed with the X — for this screen only, and NEVER a decision. An
    /// undecided project stays undecided (the safe state) and a disclosed grant
    /// returns next time, because dismissing is not acknowledging.
    private(set) var piTrustDismissed = false
    private(set) var piTrustApplying = false
    /// Set when an answer NEEDS pi restarted before it takes effect — which is
    /// knowable from the answer itself — as opposed to whether it already has
    /// been, which is not: nothing this client can observe distinguishes a
    /// running pi from none, and it has no safe way to end one (see
    /// ``answerPiTrust(_:restart:)``). The message it drives is phrased
    /// conditionally for exactly that reason.
    private(set) var piTrustSavedNotApplied = false
    /// Surfaced only for a WRITE that failed — the read-only probe stays silent.
    var piTrustError: String?
    private var piTrustTask: Task<Void, Never>?

    // MARK: - Draft new-session selection

    /// The draft's chosen agent (new session only; nil for existing). The
    /// authoritative agent for a linked/existing conversation is the summary's.
    private(set) var selectedAgent: AgentType?
    /// Agents offered in the draft's in-page picker (narrowed to installed/enabled).
    /// Seeded with the built-ins only; the server's list (which may add custom
    /// ACP agents) replaces it as soon as `loadDraftPickers` returns.
    private(set) var availableAgents: [AgentType] = AgentType.builtins
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

    /// The best-known prompt capabilities for the agent this screen talks to, and
    /// the connection that value was confirmed against.
    ///
    /// Nil means "not established yet", which is the common case: the only source
    /// is a *live* session, and an idle conversation has none. It is filled
    /// opportunistically from snapshot reads the screen already makes, and
    /// authoritatively — once per connection — by the send path before it encodes
    /// an attached image.
    private(set) var promptCapabilities: PromptCapabilities?
    private var promptCapabilitiesConnection: String?

    /// Whether to offer image attachment at all. Optimistic while unknown: the
    /// alternative is withholding the feature from every agent that accepts it
    /// (capabilities are unknown until a session is live), and a send that can't
    /// be encoded still reaches the agent's own error. Only a live session that
    /// positively rejects both encodings hides the "+" menu's Attach section.
    var canAttachImages: Bool { promptCapabilities?.canAttachImages ?? true }

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

    /// The AIR session-failure table of the attached connection (web
    /// `sessionFailures`): upserts merged per id, resolution inferred here
    /// (see ``SessionFailures``). The dock under the transcript draws only
    /// what is still in progress — an incident the adapter is retrying, and a
    /// short "recovered" line after it.
    private(set) var sessionFailures: [SessionFailureRecord] = []
    /// The connection `sessionFailures` belongs to — their ids (and so the
    /// revision watermarks) mean nothing on another one.
    private var sessionFailuresConnection: String?
    /// The retry the agent is making on its own right now (web
    /// `claudeApiRetry`), cleared by the next output or the turn's end.
    private(set) var turnRetry: TurnRetryState?

    /// What the dock under the transcript shows (web `ComposerStatusStrips`).
    var sessionFailureDock: SessionFailures.DockView {
        SessionFailures.dock(sessionFailures, turnRunning: isTurnActive, retryLineShown: turnRetry != nil)
    }

    /// Close a dock strip — every record it stands for.
    func dismissSessionFailures(_ ids: [String]) {
        sessionFailures = SessionFailures.dismiss(sessionFailures, ids: ids)
    }

    // MARK: - Mid-turn messages (queue + live feedback)

    /// Messages written while a turn was running (or behind ones that were),
    /// sent one at a time once the agent is free (web `useMessageQueue`).
    private(set) var queue = MessageQueue()
    /// Auto-sending is paused: the last message to leave the queue was turned
    /// away for a reason a retry would only hit again. The user's next send —
    /// or "send now" on the strip — resumes it.
    private(set) var queueHeld = false
    /// When a message last bounced off a turn that was still running, for the
    /// flush backoff.
    private var lastQueueBounceAt: ContinuousClock.Instant?
    private var queueFlushTask: Task<Void, Never>?
    /// Re-reads the row after a send found the conversation moved to another
    /// folder (see ``followMovedConversation(_:)``).
    private var relocationTask: Task<Void, Never>?
    /// A queued row is being inserted into the running turn. It stays queued
    /// for the round-trip — it only leaves once the backend confirms — so the
    /// flush has to keep its hands off it meanwhile, or the turn's end would
    /// send the same text twice: into the ending turn AND as the next one.
    private var queueSteerInFlight = false

    /// The global live-feedback switch (`get_feedback_settings`), re-read each
    /// time the screen appears so a change made in Settings applies on return.
    private(set) var feedbackEnabled = false
    /// The current turn's live-feedback notes.
    private(set) var feedbackNotes = FeedbackNotes()
    /// The connection the notes and channel flags below describe.
    private var feedbackConnection: String?
    /// Whether this session's agent was given the `check_user_feedback` tool,
    /// and whether it takes native `_session/steering` pushes. Snapshots only
    /// ever upgrade them (they are fixed at launch); the one downgrade signal
    /// is a submit's own result.
    private(set) var feedbackToolAvailable = false
    private(set) var nativeSteering = false
    /// Latched by that downgrade, so a stale snapshot can't flip it back.
    private var steeringDowngraded = false
    /// The connection whose flags a turn start has already re-read.
    private var feedbackFlagsRefreshed: String?
    /// The composer's draft is on its way into the running turn.
    private(set) var isSteering = false
    /// The last turn was given up on without the server ever saying it ended
    /// (the connection was lost for good). It may well still be running, so
    /// the notes it was sent are not called unread, nor offered for resending.
    private var turnEndUnconfirmed = false

    /// Whether the notes still belong to a turn that may be running.
    var feedbackTurnRunning: Bool { isInFlight || turnEndUnconfirmed }

    var steerChannel: SteerChannel { nativeSteering ? .native : .pull }

    /// A message can be sent into the turn that is running right now, over
    /// one of the session's live-feedback channels.
    var canSteer: Bool {
        feedbackEnabled && isInFlight && isTurnActive && connectionID != nil
            && (feedbackToolAvailable || nativeSteering)
    }

    /// The note rows above the composer: every note while the turn runs, then
    /// only the ones the agent never read (web `useSessionFeedback`). Notes the
    /// transcript already shows as messages are left out.
    var visibleFeedbackNotes: [FeedbackItem] {
        feedbackNotes.visible(turnRunning: feedbackTurnRunning, adopted: liveTurn?.steeredIDs ?? [])
    }

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
    /// Bumped whenever a resolved connection is deliberately retired (see
    /// ``resetDraftConnection()``), so one still in flight for the old target
    /// can't install itself — or be joined — afterwards. Field equality alone
    /// would call an agent A → B → A switch a match, and it isn't: the
    /// connection resolved for the first A was explicitly dropped in between.
    private var connectionGeneration = 0
    /// A connection resolution in flight, with the context it was made for.
    ///
    /// Shared so two callers can never resolve independently: for a draft that
    /// means two live agent processes, since `spawn_agent` dedups only when it
    /// is given a session id and a fresh session has none (it is the agent that
    /// assigns one). Keyed by context so a caller never joins a resolution
    /// aimed at the agent or folder the user has since switched away from.
    private var connectionResolution: (context: ConnectionContext, task: Task<String, Error>)?
    /// The conversation row THIS draft's first send created up front (via
    /// `create_conversation`). Held until the prompt is accepted; if the send is
    /// rolled back before then, this row is deleted so no empty conversation
    /// lingers on other clients and the draft's pickers re-open.
    private var draftCreatedConversationID: Int?
    private var stream: EventStream?
    /// The outer send pipeline (resolve connection → open stream → prompt).
    private var sendTask: Task<Void, Never>?
    /// The post-turn reconcile, and the re-anchor recovery it may end in. Held so
    /// `teardown` can stop it: it outlives the turn by design — retrying the
    /// server for seconds — and nothing else has a handle on it.
    private var reconcileTask: Task<Void, Never>?
    /// The transcript's coordinates were retired by a rewrite and have not been
    /// re-anchored yet.
    ///
    /// A view-model flag, not a local: the reconcile that OBSERVES the rewrite is
    /// not always the one that gets to act on it. A newer turn can take the
    /// reconcile over and then be rolled back before it finalizes, and then no
    /// reconcile finishes at all — leaving the window retired, which is the stall
    /// this whole path exists to end.
    private var windowNeedsReanchor = false {
        didSet {
            // Whoever records the obligation may not be in a position to act on
            // it — the reconcile that saw the rewrite often exits at its ownership
            // guard, and the send that took over may have rolled back before the
            // rewrite was even detected. Draining on the transition covers every
            // such ordering with one rule: if the screen is already idle, nothing
            // else is coming.
            if windowNeedsReanchor, !oldValue { scheduleReanchorIfIdle() }
        }
    }
    /// The standalone re-anchor recovery. Kept apart from `reconcileTask` on
    /// purpose: a drain must never cancel a reconcile, and reconciles overlap —
    /// a cancelled one unwinds long after its successor started.
    private var reanchorTask: Task<Void, Never>?
    /// How many post-turn reconciles are in their body. A COUNT, not a flag: a
    /// reconcile cancelled by the next turn's `finalize` still unwinds through
    /// its `defer` while its successor is running, and a flag cleared there would
    /// hand ownership to a drain that then cancels the successor mid-flight.
    private var reconcileDepth = 0
    /// The screen is gone RIGHT NOW. Cancelling `reconcileTask` is not enough on
    /// its own: the cancelled reconcile still unwinds through its `defer`, which
    /// drains the re-anchor obligation — and that drain would start a NEW task,
    /// with a new fetch generation, after `teardown` retired the old one.
    ///
    /// Set by `teardown` and cleared by `activate` — the `onDisappear`/`onAppear`
    /// pair — because the same model comes back when this screen pushes a route
    /// over itself. Being resettable makes it useless to anything that must not
    /// survive teardown AT ALL; for that, capture `lifecycle`.
    private var isTornDown = false
    /// Monotonic count of teardowns. Work that outlives its screen and cannot be
    /// cancelled captures this and refuses to act once it moves: unlike
    /// `isTornDown`, which a reappearance resets, a captured value is never valid
    /// again. `teardown` + a quick Back would otherwise let a task suspended
    /// before the teardown resume into the NEW lifetime, take a fresh fetch
    /// generation, and supersede the load that the user is actually waiting on.
    private var lifecycle = 0
    /// The two transcript reads the *view* asks for: the initial/retried load,
    /// and a page of older history. Owned here — and started only through
    /// `activate()` / `retryLoad()` / `requestOlderTurns()` — because a `Task`
    /// created in a view body belongs to nobody, so `teardown` cannot cancel it.
    ///
    /// Ownership is not tidiness here, it is the whole guard. Both take their
    /// fetch generation INSIDE the body, so a body still queued when `teardown`
    /// ran takes a *fresh* generation afterwards and therefore always believes
    /// it is current: the one mechanism that stops a transcript read from
    /// committing to a screen the user has left never applied to these two at
    /// all. Capturing `lifecycle` where the work is *requested* is what closes
    /// it.
    private var loadTask: Task<Void, Never>?
    private var olderTurnsTask: Task<Void, Never>?
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
            let snapshot = try await self.client.sessionSnapshot(conversationId: id)
            self.adoptPromptCapabilities(from: snapshot)
            return snapshot
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
            let snapshot = try await self.client.sessionSnapshot(conversationId: id)
            self.adoptPromptCapabilities(from: snapshot)
            return snapshot?.availableCommands ?? []
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

    // MARK: - Windowed fetch

    /// Total order over every transcript fetch this session issues — detail
    /// refreshes AND older-history pages alike. Both take a generation, so
    /// issuing either invalidates whatever else is in flight.
    ///
    /// Without a SHARED order the two silently clobber each other: a refresh
    /// requested at offset 240 is still "consistent" when it lands (same offset,
    /// same prefix hash — it was validated against the window it was requested
    /// against), so if a page prepended 120..240 during its flight, committing it
    /// replaces `turns` with the narrower suffix and the history the user just
    /// scrolled in disappears. `loadedEnd` being prepend-invariant does not catch
    /// this; only the ordering does.
    private var fetchGeneration = 0

    private func nextFetchGeneration() -> Int {
        fetchGeneration &+= 1
        return fetchGeneration
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool { fetchGeneration == generation }

    /// Result of a windowed refresh: the response, plus whether it had to
    /// re-anchor.
    private struct WindowedFetch {
        let detail: ConversationDetail
        /// The prefix was rewritten (a compaction) and the window was re-opened
        /// at the tail. Global indices captured before it are meaningless
        /// against this response — `turns_total` itself can have shrunk — so a
        /// caller's monotonic "did the transcript advance?" check cannot run,
        /// and this is NOT evidence that the response carries the caller's turn.
        let reanchored: Bool
    }

    private enum WindowedFetchOutcome {
        case fetched(WindowedFetch)
        /// A newer fetch (a history page, another refresh) superseded this one.
        /// Emphatically NOT a failure: nothing may be committed, but the turn is
        /// fine and the caller must retry rather than declare the stream lost.
        case superseded
    }


    /// Re-fetch the detail as a window scoped to what this session already holds.
    ///
    /// * No window yet (fresh session, or a server without windowing) → the
    ///   default tail.
    /// * A window → `fromIndex: offset`: refresh exactly the loaded region and
    ///   leave the unloaded prefix alone. Anchoring at the window *start* rather
    ///   than at the newest round is deliberate — turns inside the loaded region
    ///   can still be rewritten later (delegation metadata advancing, a
    ///   background task backfilling its acknowledgement), and those rewrites
    ///   should land. The unloaded prefix picks them up when it is paged in.
    ///
    /// The response is verified against the window it was requested against. A
    /// moved offset, a changed prefix hash, or a total that collapsed below the
    /// window start all mean the prefix was rewritten — a compaction — so the
    /// held coordinates describe a transcript that no longer exists. Re-open a
    /// fresh tail rather than stitch two incompatible parses together; the cost
    /// is the paged-in history, which the user can scroll back for.
    ///
    /// Returns `.superseded` when a newer fetch overtook this one — the caller
    /// must then commit nothing, and must not read that as a failure.
    private func fetchWindowedDetail(id: Int) async throws -> WindowedFetchOutcome {
        let generation = nextFetchGeneration()
        guard let current = window else {
            let detail = try await client.conversationDetail(id: id, tailTurns: Self.tailTurns)
            guard isCurrentGeneration(generation) else { return .superseded }
            return .fetched(WindowedFetch(detail: detail, reanchored: false))
        }
        let detail = try await client.conversationDetail(id: id, fromIndex: current.offset)
        guard isCurrentGeneration(generation) else { return .superseded }
        guard let fetched = TranscriptWindow(detail) else {
            return .fetched(WindowedFetch(detail: detail, reanchored: false))
        }
        if fetched.offset == current.offset,
           fetched.prefixHash == current.prefixHash,
           fetched.total >= current.offset {
            return .fetched(WindowedFetch(detail: detail, reanchored: false))
        }
        // Recorded HERE — the moment the rewrite is proven, before the round-trip
        // that fetches the replacement. That request can be overtaken or throw,
        // and the obligation has to outlive it: it is recorded on the model, not
        // returned to the caller, precisely because the reconcile that sees the
        // rewrite is often not the one that gets to act on it (see
        // ``windowNeedsReanchor``).
        windowNeedsReanchor = true
        let reset = try await client.conversationDetail(id: id, tailTurns: Self.tailTurns)
        guard isCurrentGeneration(generation) else { return .superseded }
        return .fetched(WindowedFetch(detail: reset, reanchored: true))
    }

    /// Read a session by its NATIVE id — a grok sub-agent's own transcript, which
    /// no listing returns. Lives here only so the sheet doesn't need the client;
    /// it touches none of this view model's state.
    func agentSession(agentType: AgentType, sessionId: String) async throws -> AgentSessionDetail {
        try await client.agentSession(agentType: agentType, sessionId: sessionId)
    }

    /// Adopt the coordinates a response's `turns` arrived under: where they sit in
    /// the full transcript, and which round the server says is running. Pair this
    /// with EVERY `turns = detail.turns` — the array and its window are one
    /// coordinate system, and a half-applied update mis-places the whole
    /// transcript. A `nil` window on a legacy response is the truthful answer: it
    /// carried every turn.
    private func adoptTranscriptScope(_ detail: ConversationDetail) {
        // Adopting a transcript wholesale re-establishes the coordinates, whatever
        // retired them. Paired with every wholesale `turns = detail.turns`.
        windowNeedsReanchor = false
        window = TranscriptWindow(detail)
        inFlightUserTurnId = detail.inFlightUserTurnId
    }

    /// Prepend one page of older history above the loaded window. Single-flight;
    /// a no-op when everything is already loaded.
    ///
    /// The page must *prove* it joins what is held: `prefixHashBeforeIndex`
    /// fingerprints `full[0..<beforeIndex)` from the same parse that produced the
    /// page, so it has to equal the window's own prefix hash. A mismatch means
    /// the prefix was rewritten between the two requests, and prepending would
    /// splice a stale region onto a current one.
    /// The transcript reached the head of what is loaded and wants another page.
    /// Spawned here rather than in the view so the task has an owner and captures
    /// the lifetime it was asked for (see `loadTask`/`olderTurnsTask`).
    func requestOlderTurns() {
        // Single-flight decided HERE, synchronously, and `loadingOlderTurns` set
        // here too. Deciding it in the body would be too late twice over: the
        // flag is only set a scheduling hop later, so two scroll callbacks can
        // both get past it — and the no-op second task would still have replaced
        // `olderTurnsTask`, leaving `teardown` to cancel the corpse while the
        // real request ran on unowned.
        //
        // Rejecting rather than cancel-and-restart is deliberate: the running
        // body clears the flag in its `defer`, so a replacement would race that
        // corpse and drop the page for nothing. The page in flight is the one the
        // user asked for.
        guard !loadingOlderTurns, let current = window, current.hasOlder, conversationID != nil else { return }
        loadingOlderTurns = true
        // Read where the request was MADE. Taking it inside the body would read
        // it after any teardown the body was queued across — which is precisely
        // the case this exists to reject.
        let lifetime = lifecycle
        olderTurnsTask = Task { [weak self] in await self?.loadOlderTurns(lifetime: lifetime) }
    }

    private func loadOlderTurns(lifetime: Int) async {
        // Set by `requestOlderTurns`; clearing it is this body's job, on every
        // exit including the guard below (a body whose task was cancelled before
        // it ever started still runs, so the flag is never stranded).
        defer { loadingOlderTurns = false }
        guard lifetime == lifecycle,
              let id = conversationID, let current = window, current.hasOlder else { return }

        // Joins the same total order as every detail refresh: a refresh issued
        // before this page must not commit its (now stale, narrower) suffix
        // afterwards, and a refresh issued after it supersedes it.
        let generation = nextFetchGeneration()
        guard let page = try? await client.conversationTurns(
            id: id, beforeIndex: current.offset, limit: Self.olderTurnsPage
        ) else { return }
        guard lifetime == lifecycle, isCurrentGeneration(generation) else { return }

        // The window may have moved while the page was in flight (a refresh
        // landed, the session reset): re-read it instead of trusting the capture.
        guard let now = window,
              now.offset == current.offset,
              now.prefixHash == current.prefixHash
        else { return }

        guard page.prefixHashBeforeIndex == now.prefixHash else {
            // Prefix rewritten under us. Re-anchor by refreshing — the same
            // mismatch there re-opens at the tail. Skipped while a turn is live:
            // that path owns `turns` and reconciles on its own.
            guard liveTurn == nil, !isInFlight else { return }
            if case .fetched(let fetch)? = try? await fetchWindowedDetail(id: id),
               lifetime == lifecycle, liveTurn == nil, !isInFlight {
                summary = fetch.detail.summary
                turns = fetch.detail.turns
                adoptTranscriptScope(fetch.detail)
                sessionStats = fetch.detail.sessionStats ?? sessionStats
            }
            return
        }
        guard page.turnsOffset <= now.offset else { return }

        // Defensive de-dup at the seam. The ranges are disjoint by construction;
        // this only guards against a server that rounded the page bounds outward.
        let existing = Set(turns.map(\.id))
        let fresh = page.turns.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty || page.turnsOffset < now.offset else { return }
        turns = fresh + turns
        // `total` keeps the window's own (newer) value: the page reports the same
        // parse it was sliced from, which never saw the loaded tail's latest turns.
        window = TranscriptWindow(offset: page.turnsOffset, total: now.total, prefixHash: page.prefixHash)
    }

    // MARK: - Load

    /// Guards the one-time draft option load so a re-run of `.task` can't refetch.
    private var didLoadDraftOptions = false

    /// The screen is on screen. Call from `.onAppear`, which — unlike `load()` —
    /// only runs when the view really is being shown.
    ///
    /// `teardown` runs on `.onDisappear`, and that fires when this detail merely
    /// pushes another route on top of itself; the view keeps the SAME `@State`
    /// model, so the way back has to undo it. Reappearing is also a drain point:
    /// teardown cancelled any pending recovery and left the obligation owed, its
    /// `didSet` cannot re-fire (already true), and a `.new`-mode model that has
    /// since linked returns from `load()` without fetching at all — so nothing
    /// else would restart it.
    func activate() {
        isTornDown = false
        startLoad()
        scheduleReanchorIfIdle()
        loadFeedbackSetting()
        // Teardown cancelled any flush that was waiting.
        scheduleQueueFlush()
    }

    /// The error view's "try again". Distinct from `activate()` only in where it
    /// is called from — the guarantee it needs is the same one.
    func retryLoad() {
        startLoad()
    }

    /// The single place a load is started. `lifecycle` is read HERE, synchronously,
    /// at a point that is provably inside the screen's lifetime: `onAppear` is
    /// running, or the user just tapped a button on a visible error view.
    ///
    /// Reading it at the top of `load()` instead would be worthless. A tap can be
    /// the last thing the user does before navigating away, and a `.task`
    /// cancelled before it ever started still runs its body — so the body can
    /// begin *after* `teardown`, where `lifecycle` has already moved and the read
    /// returns the new value.
    private func startLoad() {
        let lifetime = lifecycle
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load(lifetime: lifetime) }
    }

    private func load(lifetime: Int) async {
        // Returning early is not enough to be safe here, it is required: `load`
        // takes a fetch generation, so a body that ran on anyway would supersede
        // the load the user is actually waiting on, and end by re-attaching the
        // stream `teardown` had just closed.
        guard lifetime == lifecycle else { return }
        // NOT an activation point — see `activate()`. Draining here is safe
        // because `isTornDown` gates it: a live load whose fetch left the
        // obligation owed gets one more chance to clear it.
        defer { scheduleReanchorIfIdle() }
        switch mode {
        case .existing(let id):
            phase = .loading
            do {
                // Takes a generation like every other transcript fetch: a `.task`
                // re-run must not commit its fresh tail over a window the user has
                // meanwhile paged, and a page issued during this load supersedes it.
                let generation = nextFetchGeneration()
                async let detailReq = client.conversationDetail(id: id, tailTurns: Self.tailTurns)
                async let foldersReq = client.listFolders()
                let detail = try await detailReq
                let folders = try await foldersReq
                // Torn down while these were in flight. Commit NOTHING — not even
                // the window-independent fields, and above all not
                // `reattachIfLive`, which would re-open the stream `teardown` just
                // closed. Unlike `stale` below, `phase` needs no rescue here: this
                // screen is gone, and if it came back it brought a load of its own
                // that owns `phase` from `.loading` onward. Everything from here to
                // the reattach is synchronous, so this one check covers all of it.
                guard lifetime == lifecycle else { return }
                // Superseded: adopt only the fields that describe the FULL
                // transcript regardless of window (identity, stats, folders) and
                // leave `turns`/`window` to whatever overtook this load. Falling
                // out of the method instead would strand `phase` on `.loading`.
                let stale = !isCurrentGeneration(generation)

                summary = detail.summary
                if !stale {
                    turns = detail.turns
                    adoptTranscriptScope(detail)
                }
                sessionStats = detail.sessionStats
                allFolders = folders
                folder = folders.first { $0.id == detail.summary.folderId }
                currentBranch = detail.summary.gitBranch ?? folder?.gitBranch
                insertModel.agentType = detail.summary.agentType
                phase = .loaded
                // The agent and folder are only known now, and they are what
                // decides whether pi has anything to ask about.
                refreshPiTrust()
                // Initial load lands at the latest message — but not when this
                // load was superseded; the transcript belongs to something else.
                if !stale { requestStickToBottom() }
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
                await reattachIfLive(serverSaysLive: serverSaysLive, lifetime: lifetime)
            } catch {
                // A CANCELLED load lands here too — both `teardown` and a retry
                // cancel the one in flight, and `URLSession` reports that as a
                // thrown error like any other. Neither is a failure the user
                // caused, and writing `.failed` would paint an error over the
                // `.loading` its own replacement has already put up.
                guard !Task.isCancelled, lifetime == lifecycle else { return }
                phase = .failed(Self.describe(error))
            }

        case .new(let request):
            // A blank draft: show the composer immediately, then populate the
            // folder + agent lists so the in-page pickers (the nav-bar agent
            // button) are ready. Nothing is sent until the user writes + taps send.
            phase = .loaded
            // Deliberately NOT lifetime-guarded past here, unlike `.existing`.
            // This population is one-shot: a load that comes back with the screen
            // sees `didLoadDraftOptions` and returns without fetching, so refusing
            // to commit from the older lifetime would leave the pickers empty for
            // good. It writes only local picker state — no transcript, no stream.
            guard !didLoadDraftOptions else { return }
            didLoadDraftOptions = true
            await loadDraftOptions(preselectedFolderID: request.preselectedFolderID)
        }
    }

    // MARK: - pi project trust

    /// What this workspace needs answered before pi can load what it ships, if
    /// anything.
    enum PiTrustNotice: Equatable {
        /// Nothing covers this folder, so pi is skipping the repo's `.pi/*`.
        case undecided
        /// A grant is in force that nobody here confirmed — written for this
        /// folder by an older codeg, or inherited from an ancestor it seeded
        /// (which covers repos cloned into that ancestor long afterwards). pi
        /// runs `.pi/extensions` at startup, so a warning after connecting would
        /// come too late: the backend REFUSES to launch pi while this stands,
        /// and answering is what releases it.
        case undisclosedGrant
    }

    /// The notice to show above the composer, or nil when there is nothing to
    /// decide. Deliberately does not require a live connection — the gate's whole
    /// job is to stop one from existing until this is answered.
    var piTrustNotice: PiTrustNotice? {
        guard !piTrustDismissed, agentTypeForUI == .pi,
              let probe = piTrust, probe.requestedFor == folder?.path,
              !probe.state.resources.isEmpty else { return nil }
        if probe.state.decision == nil { return .undecided }
        if probe.state.decision == true, !probe.state.acknowledged { return .undisclosedGrant }
        return nil
    }

    /// The probed state behind ``piTrustNotice`` (resource list, deciding folder,
    /// trust file) for the detail sheet.
    var piTrustState: PiProjectTrustState? { piTrustNotice == nil ? nil : piTrust?.state }

    /// True while a turn is running: pi cannot be restarted underneath it, so
    /// every answer is disabled rather than half-applied.
    var piTrustActionsDisabled: Bool { piTrustApplying || isInFlight }

    /// The probe's inputs changed (screen opened, or the draft's agent/folder
    /// edited). Retires anything in flight, forgets the old answer, and un-dismisses
    /// — a notice dismissed for one project says nothing about the next.
    func refreshPiTrust() {
        piTrustGeneration &+= 1
        piTrust = nil
        piTrustDismissed = false
        startPiTrustProbe()
    }

    /// Re-read the state WITHOUT disturbing the dismissal — used after an answer,
    /// where the point is to see the decision take.
    private func startPiTrustProbe() {
        piTrustTask?.cancel()
        guard agentTypeForUI == .pi, let dir = folder?.path, !dir.isEmpty else { return }
        let issuedAt = piTrustGeneration
        let lifetime = lifecycle
        piTrustTask = Task { [weak self] in
            // Read-only probe: a failure simply means "don't prompt". Never
            // surface it — it would fire on every reconnect for a transient error.
            guard let state = try? await self?.client.piProjectTrustState(workspace: dir) else { return }
            // The generation is belt-and-braces: the `cancel()` above already
            // makes a superseded probe throw out of the call, and `piTrustNotice`
            // re-checks the folder at render time. It is kept because
            // cancellation is best-effort and what a stale reply would produce
            // here is one project's files shown against another's decision.
            guard let self, lifetime == self.lifecycle, issuedAt == self.piTrustGeneration else { return }
            self.piTrust = (requestedFor: dir, state: state)
        }
    }

    func dismissPiTrustNotice() { piTrustDismissed = true }

    /// Record a verdict. `true` grants, `false` declines, `nil` revokes a grant.
    /// Returns whether the answer is in effect already — true only when it needs
    /// no restart at all, never a claim about a process.
    @discardableResult
    func decidePiTrust(_ trusted: Bool?) async -> Bool {
        // Whether a restart is REQUIRED turns on what pi would load, not on the
        // verdict's value.
        // Exactly one answer changes nothing: declining a project pi was already
        // skipping, because with nothing decided it never loaded the resources
        // and there is no process state to correct. Declining a grant that is IN
        // FORCE is the opposite case — a pi running under it has the repo's
        // extensions loaded, and only a restart drops them. Captured before the
        // write, while the notice still describes what was answered.
        let wasAlreadySkipping = piTrustNotice == .undecided
        return await answerPiTrust { [weak self] workspace in
            // Always the CANONICAL workspace the probe reported, never the path
            // asked about: pi keys `trust.json` by realpath, so writing the
            // requested one would record a decision pi never reads.
            try await self?.client.setPiProjectTrust(workspace: workspace, trusted: trusted)
        } restart: { !(trusted == false && wasAlreadySkipping) }
    }

    /// Keep a grant that is already in force. pi's own `trust.json` is untouched;
    /// this records only that the user has answered, which is what releases the
    /// launch gate — so it has to get pi running too.
    @discardableResult
    func keepPiTrustGrant() async -> Bool {
        await answerPiTrust { [weak self] workspace in
            try await self?.client.acknowledgePiProjectTrust(workspace: workspace)
        } restart: { true }
    }

    /// Write an answer and report whether it is in effect immediately.
    ///
    /// Deliberately touches no connection. pi reads trust once at startup, so an
    /// answer reaches a process only when that process next starts; there is no
    /// safe way for this client to force that (see `piTrustSavedNotApplied`), and
    /// dropping the cached id would not help — a bound conversation rediscovers
    /// the same process, and a draft's connection is unbound, so dropping it
    /// strands a running agent nothing can find again.
    private func answerPiTrust(
        _ write: @escaping (String) async throws -> Void,
        restart: () -> Bool
    ) async -> Bool {
        guard let workspace = piTrust?.state.workspace, !piTrustActionsDisabled else { return false }
        piTrustApplying = true
        piTrustError = nil
        piTrustSavedNotApplied = false
        defer { piTrustApplying = false }
        do { try await write(workspace) } catch {
            piTrustError = Self.describe(error)
            return false
        }
        // Whether pi has to be restarted for this answer to take effect — NOT
        // whether it already has. Nothing observable from here can establish the
        // latter: `connectionID == nil` is not proof that no process exists (a
        // reattach clears it the moment it finds an idle one, and a lookup that
        // errors is indistinguishable from a miss), and there is no atomic
        // "restart if running" to ask for. So this reports the requirement, which
        // is knowable, instead of an outcome, which is not.
        let needsRestart = restart()
        piTrustSavedNotApplied = needsRestart
        // AWAITED, not fire-and-forget: the caller decides what to show from
        // `piTrustNotice`, and an un-awaited probe would leave it reading the
        // state from before the answer.
        startPiTrustProbe()
        await piTrustTask?.value
        return !needsRestart
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
            CustomAgentRegistry.shared.ingest(agents)
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
        refreshPiTrust()
    }

    // MARK: - Draft selection (new session only)

    /// Change the draft's agent before the first send. A different agent needs a
    /// different connection, so any one resolved by the options sheet is dropped.
    func selectAgent(_ agent: AgentType) {
        guard isDraftEditable, agent != selectedAgent else { return }
        selectedAgent = agent
        insertModel.agentType = agent
        resetDraftConnection()
        refreshPiTrust()
    }

    /// Change the draft's folder before the first send. The folder is the agent's
    /// working dir, so a change likewise invalidates any resolved connection.
    func selectFolder(_ newFolder: FolderDetail) {
        guard isDraftEditable, newFolder.id != folder?.id else { return }
        folder = newFolder
        currentBranch = newFolder.gitBranch
        resetDraftConnection()
        refreshPiTrust()
    }

    /// Drop a connection the options sheet resolved before any send, so the next
    /// option-apply / first prompt re-resolves against the new agent/folder.
    private func resetDraftConnection() {
        connectionID = nil
        // A resolution already in flight was made for the target being retired
        // here. Bumping the generation is what stops it installing itself, or
        // being joined by an apply for the new one, once it lands.
        connectionGeneration &+= 1
        // Capabilities belong to the agent that was selected, not to the screen —
        // keeping Grok's after a switch to Claude would encode the next image as
        // an embedded blob for an agent that takes native images.
        promptCapabilities = nil
        promptCapabilitiesConnection = nil
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
    ///
    /// While a turn runs — or while earlier messages are still waiting — the
    /// composer's message joins the END of the queue instead (web
    /// `shouldQueueDirectSend`): it goes out on its own once the agent is free,
    /// and never ahead of what was written before it.
    func send(overrideText: String? = nil) {
        let text = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = overrideText == nil ? attachments : []
        guard !text.isEmpty || !sending.isEmpty else { return }
        // Identity comes from the loaded summary (existing conversation) or the
        // new-task request; without either the screen isn't ready to send.
        guard summary != nil || newRequest != nil else { return }
        if overrideText == nil, isInFlight || !queue.isEmpty {
            queue.enqueue(QueuedPrompt(text: text, attachments: sending))
            draft = ""
            attachments = []
            // Sending again is also how the user resumes a held queue.
            queueHeld = false
            scheduleQueueFlush()
            return
        }
        startSend(text: text, attachments: sending, origin: overrideText == nil ? .composer : .generated)
    }

    /// Where a prompt came from — which decides where it goes if the server
    /// turns it away before accepting it.
    private enum SendOrigin: Sendable {
        /// Typed and sent: a rejection puts the text back in the composer.
        case composer
        /// The head of the queue: a rejection returns it to the front.
        case queue(QueuedPrompt)
        /// Written by the app itself (plan revision notes): it goes next.
        case generated
    }

    private func startSend(text: String, attachments sending: [Attachment], origin: SendOrigin) {
        guard !isInFlight else { return }
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
        //
        // Every settled predecessor, including an empty one: promotion is what
        // moves its optimistic USER turn into `turns` too, and that turn outlives
        // the empty reply. Skipping it left the user turn owned by nobody — no
        // live turn to promote it later, and a rollback of THIS send only removes
        // its own id — which then blocks re-anchoring indefinitely. (Promotion
        // already drops a contentless assistant snapshot on its own.)
        if let prior = liveTurn, !prior.isStreaming {
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
        if case .composer = origin {
            draft = ""
            attachments = []
        }

        // A new round: every reply above this message folds.
        replyFolds.beginRound()

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
            await self?.runSend(text: text, attachments: sending, live: live, userTurnID: userTurnID, origin: origin)
        }
    }

    private func runSend(text: String, attachments sending: [Attachment], live: LiveTurn, userTurnID: String, origin: SendOrigin) async {
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
            // Thrown, not returned: the catch is what puts an unsent message
            // back when the screen's teardown cancelled it.
            try Task.checkCancellation()

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
            // A new turn began, so whatever the lost one was doing is over.
            // (Not before acceptance: a send turned away leaves it uncertain —
            // and not if THIS turn was lost while the reply was on its way.)
            if liveTurn === live, isTurnActive { turnEndUnconfirmed = false }
        } catch let error as APIError where error.isStaleConnection {
            // Stale connection → drop it and retry once with a fresh spawn.
            connectionID = nil
            await retrySendOnce(text: text, attachments: sending, live: live, clientMessageID: clientMessageID, userTurnID: userTurnID, origin: origin)
        } catch is CancellationError {
            // The user's Stop is `cancel()`'s to settle. Teardown is not:
            // cancellation only ever lands BEFORE the prompt goes out (the
            // attach wait, the capability check), so the message would sit in
            // a placeholder that nothing sends — put it back where it came from.
            if isTornDown { restoreUnsent(text: text, attachments: sending, live: live, userTurnID: userTurnID, origin: origin) }
        } catch {
            // Reaching here means the prompt was never accepted (resolve/attach/
            // prompt threw), so the optimistic user turn never made it to the
            // server. Roll it back and surface why, instead of stranding a
            // phantom "sent" message in the transcript.
            rejectSend(error, text: text, attachments: sending, live: live, userTurnID: userTurnID, origin: origin)
        }
    }

    private func retrySendOnce(text: String, attachments sending: [Attachment], live: LiveTurn, clientMessageID: String, userTurnID: String, origin: SendOrigin) async {
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
            // Thrown, not returned: the catch is what puts an unsent message
            // back when the screen's teardown cancelled it.
            try Task.checkCancellation()
            isTurnActive = true
            if case .connecting = sendState { sendState = .thinking }
            try await sendPrompt(conn: conn, text: text, attachments: sending, clientMessageID: clientMessageID)
            draftCreatedConversationID = nil
            if liveTurn === live, isTurnActive { turnEndUnconfirmed = false }
        } catch is CancellationError {
            if isTornDown { restoreUnsent(text: text, attachments: sending, live: live, userTurnID: userTurnID, origin: origin) }
        } catch {
            rejectSend(error, text: text, attachments: sending, live: live, userTurnID: userTurnID, origin: origin)
        }
    }

    /// Undo a send the screen's teardown stopped before the prompt went out: a
    /// queued message returns to the front of the queue (the flush resumes on
    /// `activate`), anything else to the composer.
    private func restoreUnsent(text: String, attachments sent: [Attachment], live: LiveTurn, userTurnID: String, origin: SendOrigin) {
        if case .queue(let queued) = origin {
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: "", restoringAttachments: [])
            queue.requeueFront(queued)
        } else {
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text, restoringAttachments: sent)
        }
    }

    /// The server never accepted this prompt: roll the optimistic turn back,
    /// then put the message somewhere it isn't lost.
    ///
    /// - Turned away by a turn that is still running (another client's, or one
    ///   this screen hadn't seen start): into the queue, to go out once that
    ///   turn ends — exactly as if it had been written mid-turn. A message that
    ///   was the queue's head returns to the FRONT; a composer send that found
    ///   the queue empty joins it. The flush backs off before retrying.
    /// - Any other failure retries no better, so it is not retried on its own:
    ///   a composer message goes back into the composer, and a queued one back
    ///   to the front of a HELD queue, for the user to send again.
    private func rejectSend(_ error: Error, text: String, attachments sent: [Attachment], live: LiveTurn, userTurnID: String, origin: SendOrigin) {
        let prompt: QueuedPrompt
        switch origin {
        case .queue(let queued): prompt = queued
        case .composer, .generated: prompt = QueuedPrompt(text: text, attachments: sent)
        }
        if case APIError.turnInProgress = error {
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: "", restoringAttachments: [])
            lastQueueBounceAt = ContinuousClock.now
            if case .composer = origin { queue.enqueue(prompt) } else { queue.requeueFront(prompt) }
            scheduleQueueFlush()
            return
        }
        if case .queue = origin {
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: "", restoringAttachments: [])
            queue.requeueFront(prompt)
        } else {
            discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text, restoringAttachments: sent)
        }
        // Whatever was queued behind this send would most likely fail the same
        // way, one by one: wait for the user instead.
        if !queue.isEmpty { queueHeld = true }
        if let moved = ConversationMoved.from(error) {
            followMovedConversation(moved)
            return
        }
        notice = Self.describe(error)
    }

    // MARK: - Moved conversation

    /// A send found the conversation moved to another folder: the connection this
    /// screen holds was started in the folder it left, and the backend refuses
    /// every prompt on it. Follow the row there, as the web's tab does — drop the
    /// connection, so the next send finds or starts one in the new folder (the
    /// lookup only discovers connections launched where the conversation is
    /// now), and re-read the row and the folders.
    ///
    /// The message is not resent on its own: `rejectSend` already put it back in
    /// the composer (or at the front of the held queue) to send again.
    private func followMovedConversation(_ moved: ConversationMoved) {
        connectionID = nil
        // An options resolution in flight was made for the old folder's agent.
        connectionGeneration &+= 1
        // Point the next send at the new folder right away when it is known, so
        // a quick resend does not launch another agent in the old one.
        if let id = moved.folderId, let target = allFolders.first(where: { $0.id == id }) {
            folder = target
            currentBranch = target.gitBranch
        }
        let placeholder = Self.movedNotice(folderName: moved.folderId.flatMap(movedFolderName(id:)))
        notice = placeholder
        notifyConversationsChanged()

        guard let id = conversationID else { return }
        let lifetime = lifecycle
        relocationTask?.cancel()
        relocationTask = Task { [weak self] in
            guard let self else { return }
            async let detailReq = self.client.conversationDetail(id: id, tailTurns: 1)
            async let foldersReq = self.client.listFolders()
            guard let detail = try? await detailReq, let folders = try? await foldersReq,
                  !Task.isCancelled, lifetime == self.lifecycle, self.conversationID == id
            else { return }
            self.allFolders = folders
            self.summary = detail.summary
            if let target = folders.first(where: { $0.id == detail.summary.folderId }) {
                self.folder = target
            }
            self.currentBranch = detail.summary.gitBranch ?? self.folder?.gitBranch
            self.refreshPiTrust()
            // The folder may only be known now (created after this screen loaded).
            if self.notice == placeholder {
                self.notice = Self.movedNotice(folderName: self.movedFolderName(id: detail.summary.folderId))
            }
        }
    }

    private func movedFolderName(id: Int) -> String? {
        allFolders.first { $0.id == id }.map { FolderVisibility.displayName(of: $0, in: allFolders) }
    }

    private static func movedNotice(folderName: String?) -> String {
        if let folderName, !folderName.isEmpty {
            return String(localized: "This conversation was moved to \(folderName). Send your message again to continue there.")
        }
        return String(localized: "This conversation was moved to another folder. Send your message again to continue there.")
    }

    // MARK: - Queue

    /// Send the queue's head once the agent is free — the queue's one send
    /// engine (web's flush effect). Level-triggered: called wherever the screen
    /// may have just become free, and a no-op whenever it isn't, so a message
    /// re-queued after the turn's end already passed is not stranded.
    ///
    /// One message at a time: the send it starts makes the screen busy again,
    /// and the next flush waits for that turn's own end.
    private func scheduleQueueFlush() {
        guard !queue.isEmpty, !queueHeld, queueFlushTask == nil, !isTornDown else { return }
        let delay = MessageQueue.flushDelay(sinceBounce: lastQueueBounceAt.map { ContinuousClock.now - $0 })
        queueFlushTask = Task { [weak self] in
            // A turn-end commit settles first, even with no backoff to wait out.
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard let self, !Task.isCancelled else { return }
            self.queueFlushTask = nil
            self.flushQueueHead()
        }
    }

    private func flushQueueHead() {
        // The SAME readiness the send path needs, checked before dequeuing: a
        // message taken off the queue and then refused by `startSend` is lost.
        guard !isTornDown, !queueHeld, !queueSteerInFlight, !isInFlight,
              summary != nil || newRequest != nil else { return }
        if summary == nil, folder == nil || selectedAgent == nil { return }
        guard let head = queue.dequeue() else { return }
        startSend(text: head.text, attachments: head.attachments, origin: .queue(head))
    }

    /// "Send now" on a held queue.
    func resumeQueue() {
        queueHeld = false
        scheduleQueueFlush()
    }

    func removeQueued(_ id: UUID) {
        queue.remove(id)
        if queue.isEmpty { queueHeld = false }
    }

    /// Take a queued message back into the composer to rework it. Appended
    /// after whatever is being typed, so nothing in the composer is lost.
    func editQueued(_ id: UUID) {
        guard let item = queue.remove(id) else { return }
        if queue.isEmpty { queueHeld = false }
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = current.isEmpty ? item.text : current + "\n\n" + item.text
        addAttachments(item.attachments)
    }

    // MARK: - Live feedback (steering)

    /// Send the composer's draft into the running turn over the session's
    /// live-feedback channel (web `handleSteerClick`): a native session inserts
    /// it into the turn at once, a pull one records a note the agent reads at
    /// its next check.
    ///
    /// The draft clears only once the backend has the message, and only if it
    /// still says what was sent. The turn ending first is not a failure — the
    /// message goes out as the next turn instead; anything else keeps the draft.
    ///
    /// Text only: images ride the native wire alone and the pull one refuses
    /// them, so a draft with attachments is sent (queued) the ordinary way.
    func steerDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, attachments.isEmpty, canSteer, !isSteering, let conn = connectionID else { return }
        isSteering = true
        let channel = steerChannel
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSteering = false }
            let draftStillSent = { self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text }
            do {
                let item = try await self.client.submitSessionFeedback(connectionId: conn, text: text)
                if draftStillSent() { self.draft = "" }
                self.adoptSteerResult(item, connection: conn)
            } catch let error where TurnRejection.isNoActiveTurn(error) {
                if draftStillSent() { self.draft = "" }
                self.queue.enqueue(QueuedPrompt(text: text))
                self.notice = String(localized: "Queued instead — it will be sent with the next turn.")
                self.scheduleQueueFlush()
            } catch {
                self.notice = Self.steerFailure(channel, error)
            }
        }
    }

    /// A queued row's "insert into current turn" (web `handleQueueSteer`). The
    /// row stays queued for the round-trip and leaves only once delivered; if
    /// the turn ended first it simply goes next, as the next turn's prompt.
    func steerQueued(_ id: UUID) {
        guard let item = queue.items.first(where: { $0.id == id }),
              item.attachments.isEmpty, canSteer, !queueSteerInFlight,
              let conn = connectionID else { return }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queueSteerInFlight = true
        let channel = steerChannel
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.queueSteerInFlight = false
                // The flush was held for this round-trip; the turn may have
                // ended during it.
                self.scheduleQueueFlush()
            }
            do {
                let delivered = try await self.client.submitSessionFeedback(connectionId: conn, text: text)
                self.removeQueued(id)
                self.adoptSteerResult(delivered, connection: conn)
            } catch let error where TurnRejection.isNoActiveTurn(error) {
                self.queue.moveToFront(id)
                self.notice = String(localized: "Queued instead — it will be sent with the next turn.")
            } catch {
                self.notice = Self.steerFailure(channel, error)
            }
        }
    }

    private static func steerFailure(_ channel: SteerChannel, _ error: Error) -> String {
        let title = channel == .pull
            ? String(localized: "Couldn’t send your note")
            : String(localized: "Couldn’t insert into the current turn")
        return title + " — " + describe(error)
    }

    /// Record a submitted note and converge the channel on what the submit
    /// RESULT proves (web `reconcileChannel`).
    ///
    /// A `pending` note on a session thought native proves the backend already
    /// fell back to the pull path: switch, and say so — the "insert now" became
    /// a waiting note. A `delivered` one is ambiguous (the round that falls back
    /// also returns delivered), so re-read the snapshot once and converge
    /// silently if it says native steering is off.
    private func adoptSteerResult(_ item: FeedbackItem, connection conn: String) {
        guard feedbackConnection == nil || feedbackConnection == conn else { return }
        feedbackNotes.submitted(item)
        guard nativeSteering else { return }
        if !item.isDelivered {
            steeringDowngraded = true
            nativeSteering = false
            notice = String(localized: "Instant insert isn’t available in this session — your note was saved for the agent to pick up on its next check.")
            return
        }
        Task { [weak self] in
            guard let snapshot = try? await self?.client.connectionSnapshot(connectionId: conn) else { return }
            // Only an explicit `false`: an older server omits the field.
            guard let self, self.feedbackConnection == conn, snapshot.nativeSteeringAvailable == false else { return }
            self.steeringDowngraded = true
            self.nativeSteering = false
        }
    }

    /// An unread note from a turn that is over, sent as an ordinary message.
    func resendFeedbackNote(_ id: String) {
        guard !feedbackTurnRunning, let note = feedbackNotes.notes.first(where: { $0.id == id }) else { return }
        feedbackNotes.dismiss(id)
        queue.enqueue(QueuedPrompt(text: note.text))
        queueHeld = false
        scheduleQueueFlush()
    }

    func dismissFeedbackNote(_ id: String) {
        feedbackNotes.dismiss(id)
    }

    /// Adopt a snapshot's feedback state. The note list only when it can
    /// describe the turn on screen — the pre-prompt attach snapshot of a send
    /// still holds the PREVIOUS turn's notes — while the channel flags are
    /// session facts and always welcome (monotonic upgrades only).
    private func hydrateFeedback(from snap: LiveSessionSnapshot, connection conn: String, notes: Bool) {
        if feedbackConnection != conn {
            feedbackConnection = conn
            feedbackNotes = FeedbackNotes()
            feedbackToolAvailable = false
            nativeSteering = false
            steeringDowngraded = false
            feedbackFlagsRefreshed = nil
        }
        if snap.feedbackToolAvailable { feedbackToolAvailable = true }
        if snap.nativeSteeringAvailable, !steeringDowngraded { nativeSteering = true }
        if notes { feedbackNotes.hydrate(snap.feedback) }
    }

    /// A fresh connection is attached before its agent has finished starting,
    /// so the attach snapshot can report no channel yet; read the flags again
    /// once its first turn is underway (web's self-heal), at most once.
    private func refreshFeedbackFlagsIfUnknown() {
        guard feedbackEnabled, !(feedbackToolAvailable && nativeSteering),
              let conn = connectionID, feedbackConnection == conn,
              feedbackFlagsRefreshed != conn else { return }
        feedbackFlagsRefreshed = conn
        Task { [weak self] in
            guard let snapshot = try? await self?.client.connectionSnapshot(connectionId: conn) else { return }
            guard let self, self.feedbackConnection == conn else { return }
            if snapshot.feedbackToolAvailable == true { self.feedbackToolAvailable = true }
            if snapshot.nativeSteeringAvailable == true, !self.steeringDowngraded { self.nativeSteering = true }
        }
    }

    private func loadFeedbackSetting() {
        Task { [weak self] in
            guard let enabled = try? await self?.client.feedbackEnabled() else { return }
            self?.feedbackEnabled = enabled
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

    /// Everything a connection resolution is *for*: the inputs it is made from,
    /// plus the generation that retires it wholesale.
    ///
    /// A resolution is only this screen's while every one of these still holds.
    /// The draft's agent and folder are editable until the first send, and that
    /// send then links a conversation — so an id that comes back afterwards can
    /// easily be the answer to a question nobody is asking any more.
    private struct ConnectionContext: Equatable {
        let generation: Int
        let conversationID: Int?
        let agentType: AgentType
        let workingDir: String?
        let sessionID: String?
    }

    private var connectionContext: ConnectionContext {
        ConnectionContext(
            generation: connectionGeneration,
            conversationID: conversationID,
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionID: summary?.externalId
        )
    }

    /// Resolve a live chat connection for out-of-band actions — currently applying
    /// agent mode/config from the options sheet. Unlike the send path, this does
    /// NOT trust a cached `connectionID`: it re-validates liveness first and only
    /// spawns a fresh one when none is live, so a mode/config change can't be sent
    /// to a connection the server has since garbage-collected. The result is cached
    /// so the next send reuses the same connection.
    ///
    /// The whole resolution runs against one immutable context, captured here: it
    /// is what the request is built from, what decides whether the id may be
    /// cached, and what scopes the sharing below.
    func resolveConnectionForOptions() async throws -> String {
        let context = connectionContext
        let resolution: Task<String, Error>
        if let inFlight = connectionResolution, inFlight.context == context {
            resolution = inFlight.task
        } else {
            resolution = Task { [weak self] () async throws -> String in
                guard let self else { throw APIError.transport("Session closed.") }
                defer { self.retireResolution(for: context) }
                return try await self.performConnectionResolution(for: context)
            }
            connectionResolution = (context, resolution)
        }
        let conn = try await resolution.value
        // Awaiting an unstructured task does not observe THIS caller's own
        // cancellation, so ask explicitly. An apply torn down mid-resolve has to
        // fail: its revert is what keeps the remembered selection in step with
        // the one on screen.
        try Task.checkCancellation()
        return conn
    }

    /// Stop sharing a resolution once it has produced its answer, so the next
    /// apply re-validates liveness instead of replaying a possibly-dead id.
    ///
    /// Keyed by context rather than by task identity because that is exactly as
    /// precise here: at most one resolution per context can be in flight, since
    /// a second caller in the same context joins the first instead of installing
    /// its own.
    private func retireResolution(for context: ConnectionContext) {
        if connectionResolution?.context == context { connectionResolution = nil }
    }

    private func performConnectionResolution(for context: ConnectionContext) async throws -> String {
        if let id = context.conversationID {
            // A linked conversation carries its connection, so liveness is just a
            // lookup: `findConnection` returns the bound one or nil.
            if let found = try await client.findConnection(
                conversationId: id,
                sessionId: context.sessionID,
                agentType: context.agentType
            )?.connectionId {
                adoptResolvedConnection(found, for: context)
                return found
            }
        } else if let existing = connectionID,
                  let snapshot = try? await client.connectionSnapshot(connectionId: existing),
                  !snapshot.isConnectionOver {
            // A draft has no conversation to look a connection up by, so the
            // cached id is the only handle on the agent already spawned for it —
            // ask that connection directly instead. Reconnecting blind would
            // start a SECOND agent process (a fresh session can't dedup) and
            // leave the setting just applied on the first, which is precisely
            // the "never spawns a second one" this resolver exists to keep.
            return existing
        }
        let prefs = SelectorPrefsStore.prefs(for: context.agentType)
        let conn = try await client.connect(
            agentType: context.agentType,
            workingDir: context.workingDir,
            sessionId: context.sessionID,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
        adoptResolvedConnection(conn, for: context)
        return conn
    }

    /// Cache a resolution only while the screen is still the thing it was resolved
    /// for. `connectionID` is what the next prompt, the interactive replies and the
    /// stop button all target, so one that lands late — after the draft moved to
    /// another agent, or after the first send linked a conversation and resolved
    /// its own — must not overwrite the connection actually in use.
    ///
    /// The resolution itself is still handed back to its caller: an apply made for
    /// agent A has to reach A's connection either way, or its revert would undo a
    /// selection the user made deliberately.
    private func adoptResolvedConnection(_ conn: String, for context: ConnectionContext) {
        guard connectionContext == context else { return }
        connectionID = conn
    }

    /// How long to keep asking a connection what it accepts, matching the
    /// backend's own `IMAGE_CAPABILITY_WAIT`. A wait is needed at all because
    /// `acp_connect` returns as soon as the agent process is registered: a fresh
    /// session's `initialize` — which is what publishes capabilities — is still in
    /// flight, and the snapshot route answers immediately with whatever it has.
    /// Reading once would hand a brand-new Grok session the native image block it
    /// rejects, which is the exact failure this routing exists to prevent.
    private static let promptCapabilityWait: Duration = .seconds(20)

    /// The capabilities of the connection this prompt is about to reach: resolved
    /// once per connection, and only for a prompt that actually carries an image —
    /// the same rule the backend applies before re-encoding a work task's
    /// attachments, so no text-only send pays for any of this. The by-connection
    /// route is used rather than the by-conversation one because it also answers
    /// in the pre-first-prompt window, where a draft's fresh connection isn't
    /// bound to a conversation yet.
    ///
    /// Polls (unlike the backend's in-process wait, each ask is a round-trip, so
    /// the interval backs off) and stops early on the three terminal answers:
    /// capabilities published, connection gone, connection dead.
    ///
    /// Best-effort by design: running out of budget, a transport failure, or a
    /// session that publishes nothing all fall back to whatever was learned
    /// earlier — possibly nil, i.e. send natively. A capability lookup must never
    /// be the thing that stops a message going out, and guessing wrong costs no
    /// more than today: the agent's own error.
    private func resolvePromptCapabilities(on conn: String) async -> PromptCapabilities? {
        if promptCapabilitiesConnection == conn, let known = promptCapabilities { return known }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.promptCapabilityWait)
        var interval: Duration = .milliseconds(200)
        while !Task.isCancelled {
            let snapshot: SessionSnapshot?
            do {
                snapshot = try await client.connectionSnapshot(connectionId: conn)
            } catch {
                return promptCapabilities   // no information; stop asking
            }
            guard let snapshot else { return promptCapabilities }   // connection gone
            if let caps = snapshot.promptCapabilities {
                promptCapabilities = caps
                promptCapabilitiesConnection = conn
                return caps
            }
            // A dead session will never advertise anything.
            if snapshot.isConnectionOver { return promptCapabilities }
            guard clock.now < deadline else { break }
            // Cancellation makes the sleep return at once; the loop condition
            // catches it on the next pass.
            try? await Task.sleep(for: interval)
            interval = min(interval * 2, .seconds(1))
        }
        return promptCapabilities
    }

    /// Take the capabilities off a live-session snapshot the screen read for some
    /// other reason (the options sheet, the slash-command list) — free, and enough
    /// to gate the "+" menu before any send. Never *clears* a known value: a
    /// snapshot without them means this session has published none yet, not that
    /// the agent has none. The connection is deliberately left unrecorded, so the
    /// send path still makes its own authoritative read against the connection it
    /// is actually prompting.
    private func adoptPromptCapabilities(from snapshot: SessionSnapshot?) {
        guard let caps = snapshot?.promptCapabilities else { return }
        promptCapabilities = caps
    }

    private func sendPrompt(conn: String, text: String, attachments sending: [Attachment], clientMessageID: String) async throws {
        // Text first, then images — matches the web client's block order.
        var blocks: [PromptInputBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        if !sending.isEmpty {
            let caps = await resolvePromptCapabilities(on: conn)
            blocks.append(contentsOf: sending.map { $0.promptInputBlock(for: caps) })
            // Resolving capabilities can wait on a fresh agent's handshake, which
            // is long enough for the user to hit Stop. `cancel()` has already torn
            // the stream down by then, so prompting anyway would start a turn with
            // nothing listening; `runSend` treats this throw as the no-op it is.
            try Task.checkCancellation()
        }
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
                  // Identity + stats only — those describe the full transcript
                  // whatever window is asked for, so ask for the smallest one
                  // and leave `turns` (and the window) untouched.
                  let detail = try? await self.client.conversationDetail(id: id, tailTurns: Self.identityTurns),
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
                //
                // A RECONNECT (past the handshake) resumes from the last event
                // applied, so the server replays what the dropped socket missed —
                // without it every delta in the gap was lost for good.
                let resumeFrom = readyContinuation == nil ? live.lastSeq : nil
                stream.attach(subscriptionId: subscriptionID, connectionId: conn, sinceSeq: resumeFrom)
            case .snapshot(let snap):
                // Attach confirmed — a healthy socket. Reset the reconnect budget
                // and (for the initial connect) release the waiting send.
                streamReconnects = 0
                if isCurrent, let seq = snap.eventSeq { live.lastSeq = seq }
                if isCurrent {
                    hydrateSessionFailures(from: snap, connection: conn)
                    // The handshake's snapshot predates this prompt: its notes
                    // are the previous turn's. A reconnect's describe this one.
                    hydrateFeedback(from: snap, connection: conn, notes: readyContinuation == nil)
                }
                // A reconnect answered with a snapshot rather than a replay —
                // first attach after a drop with no cursor, or a gap too large
                // to replay. Either the turn ended while the socket was down, or
                // it is still running and the snapshot is the only full account
                // of what was streamed in the gap.
                if isCurrent, readyContinuation == nil, isTurnActive, liveTurn === live,
                   resumeAfterReconnect(live: live, snapshot: snap) {
                    return
                }
                // A mid-turn RECONNECT can drop the socket exactly as a
                // `permission_request` / `question_request` arrives — losing that
                // live event. The fresh snapshot still carries the pending card, so
                // restore it; otherwise an ExitPlanMode / permission prompt is
                // silently lost across the reconnect and the reply "looks finished"
                // with no way to approve. Mirrors `consumeReattach` + the web client.
                // Skipped during the INITIAL attach handshake (readyContinuation set)
                // — that snapshot is the pre-prompt state and carries no live card.
                if isCurrent { resumeReady(throwing: nil) }
            case .replay(let events):
                streamReconnects = 0
                // The events the dropped socket missed, in order. Applied like
                // live ones (they used to be discarded unread).
                if isCurrent {
                    for envelope in events where liveTurn === live {
                        apply(envelope, to: live)
                    }
                    resumeReady(throwing: nil)
                }
            case .pong:
                break
            case .event(let envelope):
                if isCurrent { apply(envelope, to: live) }
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
                    // Lifetime captured HERE, not inside the callee: the task is
                    // only ENQUEUED now, and a teardown + reappearance can both run
                    // before its body starts — at which point reading `lifecycle`
                    // there would read the NEW one and wave the task through.
                    let lifetime = lifecycle
                    Task { [weak self] in
                        await self?.reconcileOrFail(live: live, reason: reason, lifetime: lifetime)
                    }
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
    ///
    /// `lifetime` is the caller's captured `lifecycle`. Discovery can spend
    /// seconds in backoff, and `isTornDown` is NOT enough to guard it: `activate`
    /// clears that flag, so a teardown and a reappearance in the gap leave it
    /// false again and this would sail through into a lifetime it does not belong
    /// to — taking a fetch generation and opening a stream there.
    func reattachIfLive(serverSaysLive: Bool = false, lifetime: Int) async {
        guard lifetime == lifecycle, let id = conversationID, summary != nil else { return }
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
            // Bail if a send (or another reattach) started while we awaited — or
            // if the screen this discovery belongs to is over.
            guard lifetime == lifecycle, liveTurn == nil, !isInFlight, stream == nil else { return }
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
            if serverSaysLive { await reconcileAfterMissedLive(lifetime: lifetime) }
            return
        }

        // Re-check: a send may have started while we awaited — or the screen may
        // have gone. The whole point of `teardown` closing the stream is undone
        // by opening a new one after it.
        guard lifetime == lifecycle, liveTurn == nil, !isInFlight, stream == nil else { return }

        connectionID = conn
        closeStream()
        streamGeneration &+= 1
        let generation = streamGeneration
        let newStream = EventStream(baseURL: client.baseURL, token: client.token)
        stream = newStream
        newStream.start()
        consumerTask = Task { [weak self] in
            await self?.consumeReattach(stream: newStream, connectionID: conn, generation: generation, serverSaysLive: serverSaysLive, lifetime: lifetime)
        }
    }

    /// The server reported a live turn at load but we couldn't attach to it (it
    /// finished in the gap, or the connection was momentarily undiscoverable).
    /// Quietly refetch the detail so the transcript shows the final reply rather
    /// than the snapshot we loaded a beat too early. No-op if a turn has since
    /// started locally — that path owns the transcript.
    private func reconcileAfterMissedLive(lifetime: Int) async {
        guard lifetime == lifecycle, let id = conversationID, liveTurn == nil, !isInFlight, stream == nil else { return }
        guard case .fetched(let fetch)? = try? await fetchWindowedDetail(id: id) else { return }
        // Re-checked: this is reached only from the reattach path, which can have
        // spent seconds in discovery before even getting here, and the fetch
        // above is another suspension on top of that.
        guard lifetime == lifecycle, liveTurn == nil, !isInFlight, stream == nil else { return }
        let detail = fetch.detail
        summary = detail.summary
        turns = detail.turns
        adoptTranscriptScope(detail)
        sessionStats = detail.sessionStats ?? sessionStats
        requestStickToBottom()
    }

    /// Consumer for the reattach stream. Unlike `consume`, it has no `openStream`
    /// continuation to release and it BUILDS the live turn from the attach snapshot
    /// rather than being handed one. If the snapshot shows nothing in flight, it
    /// closes the stream (idle connection — leave it alone).
    private func consumeReattach(stream: EventStream, connectionID conn: String, generation: Int, serverSaysLive: Bool = false, lifetime: Int) async {
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
                hydrateSessionFailures(from: snap, connection: conn)
                hydrateFeedback(from: snap, connection: conn, notes: true)
                if let rebuilt = buildLiveTurn(from: snap) {
                    live = rebuilt
                    liveTurn = rebuilt
                    // This live turn is the snapshot's complete in-flight reply;
                    // the transcript must hide any partial copy the agent has
                    // begun persisting into `turns` so the reply isn't doubled.
                    liveTurnFromReattach = true
                    replyFolds.arm()
                    isTurnActive = true
                    turnEndUnconfirmed = false
                    restorePending(from: snap)
                    sendState = .thinking
                    requestStickToBottom()
                } else {
                    // A reconnect that finds the connection idle: the turn this
                    // screen was showing ENDED while the socket was down, and its
                    // `turn_complete` went to nobody. Settle it the way that event
                    // would have — otherwise it stays "running" until reopened.
                    // (A first reattach never gets here with a turn active.)
                    if isTurnActive, let prior = liveTurn {
                        recordSnapshotFailure(snap, on: prior)
                        finalize(live: prior, stopReason: "end_turn")
                        return
                    }
                    // Idle connection: nothing in flight. Release it. Whatever
                    // turn this screen lost track of is over, too.
                    turnEndUnconfirmed = false
                    closeStream()
                    connectionID = nil
                    // If the server had claimed a live turn at load, it finished
                    // between the detail fetch and this snapshot — reconcile so the
                    // final reply isn't missing from the (now stale) transcript.
                    // (Before surfacing any error below: the reconcile bails when
                    // `liveTurn` is already set.)
                    if serverSaysLive { await reconcileAfterMissedLive(lifetime: lifetime) }
                    surfaceSettledError(from: snap)
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
                    // Lifetime captured HERE, not inside the callee: the task is
                    // only ENQUEUED now, and a teardown + reappearance can both run
                    // before its body starts — at which point reading `lifecycle`
                    // there would read the NEW one and wave the task through.
                    let lifetime = lifecycle
                    Task { [weak self] in
                        await self?.reconcileOrFail(live: live, reason: reason, lifetime: lifetime)
                    }
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
        // Sub-agent blocks are applied in a second pass so routing does not depend
        // on where the snapshot happens to place them relative to their parent's
        // `tool_call_ref` — by then every tool call the snapshot carried exists,
        // and the orphan gate rejects only genuinely parentless residue.
        //
        // Deferring is also what makes a reattach render identically to having
        // watched the stream: main-thread blocks land back-to-back here and merge
        // exactly as they did live, instead of being split by the interleaved
        // sub-agent blocks the wire preserves between them.
        var subAgent: [(parent: String, text: String, thinking: Bool)] = []
        for block in blocks {
            switch block {
            case .text(let t, let parent):
                if let parent { subAgent.append((parent, t, false)) } else { live.appendText(t) }
            case .thinking(let t, let parent):
                if let parent { subAgent.append((parent, t, true)) } else { live.appendThinking(t) }
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
        for entry in subAgent {
            if entry.thinking {
                live.appendThinking(entry.text, parentToolUseId: entry.parent)
            } else {
                live.appendText(entry.text, parentToolUseId: entry.parent)
            }
        }
        applySnapshotError(snap, to: live)
        live.flushAllText()
        return live
    }

    /// Stamp an error this client was not around for onto a turn.
    ///
    /// Attaching is its only channel — the live event already fired — so without
    /// this, a cold attach shows a turn that silently produced nothing.
    ///
    /// Safe with respect to staleness: the server clears `last_error` on the
    /// `Prompting` transition that begins every prompt, so a connection's copy
    /// always belongs to the most recent turn, never an older one. Scoped to
    /// errors that actually carry evidence (the inferred `turn_failed_empty*`
    /// family), so attaching to a connection with some ordinary past error does
    /// not start surfacing failures it never used to.
    @discardableResult
    private func applySnapshotError(_ snap: LiveSessionSnapshot, to live: LiveTurn) -> Bool {
        guard let lastError = snap.lastError,
              let evidence = lastError.details?.trimmingCharacters(in: .whitespacesAndNewlines),
              !evidence.isEmpty
        else { return false }
        live.errorDetails = evidence
        if live.errorMessage == nil {
            let message = lastError.message.trimmingCharacters(in: .whitespacesAndNewlines)
            live.errorMessage = message.isEmpty ? String(localized: "The agent reported an error.") : message
        }
        return true
    }

    /// Surface a snapshot's error on an IDLE connection — the common case, not an
    /// edge one: the server emits the inferred error and `TurnComplete` back to
    /// back, and `TurnComplete` clears the live message while keeping
    /// `last_error`. So any client that opens the session a moment later finds
    /// nothing in flight and would, without this, be left with a turn that
    /// produced no reply and no stated reason.
    ///
    /// The turn is born settled: `isStreaming` false (so `isInFlight` stays
    /// false), no `isTurnActive`, no `liveTurnFromReattach` (nothing to hide in
    /// the persisted transcript), and `sendState` untouched. It is a tombstone
    /// carrying one error node, not a reply.
    private func surfaceSettledError(from snap: LiveSessionSnapshot) {
        guard liveTurn == nil else { return }
        let tombstone = LiveTurn()
        tombstone.isStreaming = false
        guard applySnapshotError(snap, to: tombstone) else { return }
        liveTurn = tombstone
        requestScrollToBottom()
    }

    private func restorePending(from snap: LiveSessionSnapshot) {
        if let p = snap.pendingPermission {
            pendingPermission = PendingPermission(requestId: p.requestId, toolCall: p.toolCall, options: p.options,
                                                  liveInfo: liveTurn?.permissionLiveInfo(for: p.toolCall))
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

    /// Fill a showing permission card in from the call an event just touched —
    /// the request may have arrived before it. Only reassigned when the merge
    /// lends something, so streaming updates don't churn the card.
    private func refreshPendingPermission(from live: LiveTurn, toolCallId: String) {
        if let refreshed = pendingPermission?.refreshed(by: live, toolCallId: toolCallId) {
            pendingPermission = refreshed
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
        // Only the turn's own opening counts: the backend delivers stray
        // updates BETWEEN turns too (a late tool update, a straggling delta),
        // and one of those arriving before this prompt starts would otherwise
        // read as "this turn is running".
        case .statusChanged(.prompting), .userMessage:
            live.serverTurnStarted = true
        default:
            break
        }
        trackFailureLifecycle(event)
        switch event {
        case .contentDelta(let text, let parent):
            live.appendText(text, parentToolUseId: parent)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .thinking(let text, let parent):
            live.appendThinking(text, parentToolUseId: parent)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .toolCall(let id, let title, let kind, let status, let content, let rawInput, let rawOutput, let meta):
            live.upsertToolCall(id: id, title: title, kind: kind, status: status, rawInput: rawInput, rawOutput: rawOutput, content: content, meta: meta)
            refreshPendingPermission(from: live, toolCallId: id)
            sendState = .running(tool: title.isEmpty ? "tool" : title)
            requestScrollToBottom()

        case .toolCallUpdate(let id, let title, let status, let content, let rawInput, let rawOutput, let append, let meta):
            live.updateToolCall(id: id, title: title, status: status, rawInput: rawInput, rawOutput: rawOutput, content: content, append: append, meta: meta)
            refreshPendingPermission(from: live, toolCallId: id)
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
                // The agent died. A terminal `error` (`process_exited`, …)
                // usually came first and was routed as a notice because its
                // code is not a turn verdict — this is where it ends the turn,
                // so carry its text rather than a generic line.
                // A turn failure already recorded (a code-less terminal error)
                // is the better account still.
                let cause = live.lastNonFatalError
                failLive(live, message: live.errorMessage ?? cause?.message ?? "The agent connection errored.",
                         details: live.errorMessage == nil ? cause?.details : nil)
            default:
                break
            }

        case .usageUpdate(let used, let size):
            applyUsage(used: used, size: size)

        case .userMessage:
            // The server echoes our own prompt; we already showed it optimistically.
            // A new turn: notes are turn-scoped, and the backend just cleared them.
            feedbackNotes.newTurn()
            refreshFeedbackFlagsIfUnknown()

        case .turnComplete(let stopReason):
            // Warnings settle at a CLEAN end only: any other exit did not
            // recover, and a failed turn's terminal record already escalated
            // the same id just before this event.
            if stopReason == "end_turn" { sessionFailures = SessionFailures.settle(sessionFailures, .warnings) }
            finalize(live: live, stopReason: stopReason)

        case .error(let message, let code, let details):
            // Only some errors end the turn (see `AcpErrorRoute`). Failing on
            // every one closed the stream on turns that were still running — a
            // dropped image or a failed compaction lost the rest of the reply.
            switch AcpErrorRoute.route(code: code, message: message) {
            case .failsTurn(let text):
                // Recorded on the turn, NOT ended here — the web does the same.
                // The backend always follows a turn verdict with
                // `turn_complete` (or, if the agent died, `status_changed:
                // error`), and letting that end the turn is what reconciles it
                // against the transcript, whose `turn_error` line then takes
                // over from this one.
                markTurnFailed(live, message: text, details: details, fromAgent: code == nil)
            case .notice(let text):
                live.lastNonFatalError = (text, details)
                notice = text
            case .silent:
                break
            }

        case .conversationLinked(let linkedID, _):
            adoptLinkedConversation(linkedID)

        case .permissionRequest(let requestId, let toolCall, let options):
            // The agent paused for approval (incl. ExitPlanMode). Surface the card
            // above the compose bar; the turn stays in-flight until it's resolved.
            pendingPermission = PendingPermission(requestId: requestId, toolCall: toolCall, options: options,
                                                  liveInfo: live.permissionLiveInfo(for: toolCall))
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

        case .turnRetrying(let retry):
            turnRetry = retry
        case .claudeApiRetry(let retry):
            turnRetry = retry

        case .sessionFailure(let record):
            let stored = sessionFailures.first { $0.id == record.id }
            sessionFailures = SessionFailures.merge(sessionFailures, [record])
            switch SessionFailures.notice(stored: stored, incoming: record) {
            case .terminal?:
                // The turn closes on the adapter's own account of it — the
                // title its transcript keeps too (web `TURN_FAILED`). No notice
                // as well: the failure line already says it on this screen.
                markTurnFailed(live, message: record.ownTitle ?? record.categoryLabel,
                               details: record.details, fromAgent: record.ownTitle != nil)
            case .advisory?:
                notice = SessionNotices.present(record)
            case nil:
                break
            }

        case .sessionNotice(let info):
            if let text = SessionNotices.present(info) { notice = text }

        case .pluginLoadFailures(let failures):
            if let text = SessionNotices.present(failures) { notice = text }

        case .sessionLoadFailed(let sessionId, let message, let code):
            // A `status_changed: error` follows and ends the turn — with this
            // as its reason rather than a generic "connection errored".
            let agent = summary?.agentType
            let text = SessionNotices.sessionLoadFailure(
                code: code, message: message, sessionId: sessionId,
                agent: agent?.label ?? String(localized: "The agent"), agentIsCodex: agent == .codex)
            live.lastNonFatalError = (text, nil)

        case .feedbackSubmitted(let item):
            feedbackNotes.submitted(item)
            // Already `delivered` means it rode native steering: the agent has
            // it as a user message, so the transcript shows it as one, closing
            // the reply so far (web `STEERING_MESSAGE`). A `pending` note is the
            // pull channel's and stays a row above the composer. Out of turn
            // there is no reply to split, and the note keeps its row.
            if item.isDelivered, isTurnActive, live.isStreaming, liveTurn === live {
                live.insertSteering(SteeredMessage(id: item.id, text: item.text, at: Date()))
                requestScrollToBottom()
            }

        case .feedbackConsumed(let ids, let deliveredAt):
            feedbackNotes.consumed(ids: ids, at: deliveredAt)

        case .sessionStarted, .conversationStatusChanged, .userPromptSent, .unknown:
            break
        }
    }

    /// The failure table's and retry line's lifecycle, per event (web
    /// `acp-connections-context`): output proves an in-flight retry incident
    /// recovered and ends the retry line; a new prompt acknowledges every
    /// failure; leaving `prompting` or any error ends the retry.
    private func trackFailureLifecycle(_ event: AcpEvent) {
        switch event {
        case .contentDelta, .thinking, .toolCall:
            if SessionFailures.hasActiveRetryIncident(sessionFailures) {
                sessionFailures = SessionFailures.settle(sessionFailures, .retryIncidents)
            }
            turnRetry = nil
        case .toolCallUpdate, .planUpdate:
            turnRetry = nil
        case .statusChanged(.prompting):
            turnRetry = nil
            sessionFailures = SessionFailures.settle(sessionFailures, .all)
        case .statusChanged, .turnComplete, .error:
            turnRetry = nil
        default:
            break
        }
    }

    /// Adopt a snapshot's failure table (merged by the live rule). A different
    /// connection starts a fresh table — ids are per connection.
    private func hydrateSessionFailures(from snap: LiveSessionSnapshot, connection conn: String) {
        if sessionFailuresConnection != conn {
            sessionFailuresConnection = conn
            sessionFailures = []
            turnRetry = nil
        }
        sessionFailures = SessionFailures.merge(sessionFailures, snap.sessionFailures)
    }

    /// A new task's first prompt creates the server-side conversation; adopt
    /// its id (and identity summary) without disturbing the in-flight stream.
    private func adoptLinkedConversation(_ id: Int) {
        guard conversationID == nil else { return }
        conversationID = id
        Task { [weak self] in
            guard let self else { return }
            guard let detail = try? await self.client.conversationDetail(id: id, tailTurns: Self.identityTurns),
                  self.conversationID == id else { return }
            // Mid-stream: adopt identity + stats only — the live turn is still
            // rendering and `refreshAfterTurn()` reconciles the transcript. The
            // minimal window keeps this off the transcript's coordinate system
            // entirely (no `adoptTranscriptScope`); the reconcile opens the real one.
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
        turnEndUnconfirmed = false
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
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in await self?.refreshAfterTurn(reconciling: live) }
        // The keep-planning turn just ended — deliver the revision notes as the
        // follow-up prompt Grok expects (it discards them on the reply itself).
        if let planFollowUp { send(overrideText: planFollowUp) }
        // The agent is free: the next queued message goes out (a no-op when
        // the plan notes above already took the turn).
        scheduleQueueFlush()
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
        // This send may have taken over a reconcile that had seen the transcript
        // rewritten and then died before it could finalize. The screen is idle now.
        scheduleReanchorIfIdle()
    }

    /// Record that the running turn failed, without ending it (see the
    /// `.failsTurn` route). One account per turn: the agent's own words win
    /// over codeg's verdict whichever arrives first; otherwise the later one
    /// replaces the earlier.
    private func markTurnFailed(_ live: LiveTurn, message: String, details: String?, fromAgent: Bool) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isTurnActive else { return }
        if live.errorMessage != nil, live.errorFromAgent, !fromAgent { return }
        live.errorMessage = text
        live.errorFromAgent = fromAgent
        live.errorIsCancellation = false
        if let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            live.errorDetails = trimmed
        }
        sendState = .error(text)
        requestScrollToBottom()
    }

    private func failLive(_ live: LiveTurn, message: String?, details: String? = nil) {
        isTurnActive = false
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if let message { live.errorMessage = message }
        if let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            live.errorDetails = trimmed
        }
        // `sendState` feeds the compose status line — keep it the one-line
        // message. The evidence is multi-line and belongs in the disclosure only.
        sendState = message.map { .error($0) } ?? .idle
        closeStream()
        // Keep the live turn on screen so the user sees partial output + error;
        // drop the placeholder only if it is completely empty and errorless.
        if live.isEmpty {
            liveTurn = nil
        }
        requestScrollToBottom()
        // A turn can fail on the very fetch that discovered the rewrite
        // (`reconcileOrFail`), and failing it makes the screen idle without ever
        // reconciling — a terminal exit, so it drains. Only when the failure left
        // nothing above `turns`, though: an inline error message is itself content
        // (`isEmpty` counts `errorMessage`), so the usual failure keeps its turn on
        // screen and re-anchors on the next turn that reconciles or rolls back
        // before acceptance — the same deal an explicit cancel gets.
        scheduleReanchorIfIdle()
        // The turn died rather than ended — sending the queue into the same
        // failure one message at a time helps nobody. It waits for the user.
        if !queue.isEmpty { queueHeld = true }
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
            let lifetime = lifecycle          // captured at ENQUEUE — see `reconcileOrFail`
            Task { [weak self] in
                await self?.reconcileOrFail(live: live, reason: reason, lifetime: lifetime)
            }
            return
        }
        let attempt = streamReconnects
        // Captured at ENQUEUE, like every other spawn: the reconnect sleeps for
        // up to 8s, and the consumer it starts outlives even that.
        let lifetime = lifecycle
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
                    await self?.consumeReattach(stream: newStream, connectionID: conn, generation: generation, lifetime: lifetime)
                } else {
                    await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation)
                }
            }
        }
    }

    /// Apply one envelope to the send path's live turn, at most once. The cursor
    /// it advances is what a reconnect resumes from; an envelope at or below it
    /// was already applied (a replay overlapping the live tail) and is dropped.
    /// `seq == 0` means the frame carried none — never treated as a duplicate.
    private func apply(_ envelope: EventEnvelope, to live: LiveTurn) {
        if envelope.seq > 0 {
            if let last = live.lastSeq, envelope.seq <= last { return }
            live.lastSeq = envelope.seq
        }
        handle(event: envelope.event, live: live)
    }

    /// A turn that ended while the socket was down: carry over the failure the
    /// server recorded for it, if it failed. Routed exactly as the live `error`
    /// would have been — `last_error` holds the latest error of ANY kind, so a
    /// non-fatal one (a dropped image) must not turn into a failure here, while
    /// a real one counts whether or not it brought diagnostic `details` (a
    /// rejected prompt or most verdicts bring none). Recording it is what lets
    /// the reconcile accept the transcript's own `turn_error` line.
    private func recordSnapshotFailure(_ snap: LiveSessionSnapshot, on live: LiveTurn) {
        guard let lastError = snap.lastError else { return }
        if case .failsTurn(let text) = AcpErrorRoute.route(code: lastError.code, message: lastError.message) {
            markTurnFailed(live, message: text, details: lastError.details, fromAgent: lastError.code == nil)
        }
    }

    /// A send-path reconnect landed on a snapshot. Returns true when the turn is
    /// over and the consumer should stop.
    ///
    /// The snapshot is the connection's state NOW, so it settles both cases a
    /// replay would have covered:
    /// - not prompting — the turn ENDED while the socket was down. Its
    ///   `turn_complete` went to nobody and will not be sent again, so without
    ///   this the turn stayed "running" (Stop lit) until the session was
    ///   reopened. Finalize it and let the reconcile fetch what was persisted.
    /// - prompting — still running; the snapshot's in-flight reply is the whole
    ///   of what was streamed, gap included, so it replaces what this turn
    ///   holds.
    private func resumeAfterReconnect(live: LiveTurn, snapshot snap: LiveSessionSnapshot) -> Bool {
        // "Not prompting" means ENDED only once the server has been seen to
        // start this turn. Before that — the prompt still in flight, or queued
        // behind the connection loop — an idle snapshot is the turn not having
        // begun yet, and finalizing it would orphan the reply about to stream.
        if snap.status != .prompting, live.serverTurnStarted {
            recordSnapshotFailure(snap, on: live)
            finalize(live: live, stopReason: "end_turn")
            return true
        }
        // A prompting snapshot past the handshake is this turn running — the
        // same evidence its opening events would have been, had they arrived.
        if snap.status == .prompting { live.serverTurnStarted = true }
        if let rebuilt = buildLiveTurn(from: snap), !rebuilt.segments.isEmpty {
            live.adoptContent(from: rebuilt)
        }
        // After the adopt: a restored permission borrows from the live call it is
        // about, which may have arrived only in the gap.
        restorePending(from: snap)
        return false
    }

    /// Recovery's last resort: the socket can't be re-attached (the connection was
    /// GC'd, or reconnects kept failing). The turn may actually have completed
    /// during the outage, so re-fetch the transcript and adopt it silently when the
    /// reply has landed; only when the server still has nothing do we surface an
    /// error — and even then the partial streamed output stays on screen.
    /// `lifetime` is the `lifecycle` value read at the moment the caller ENQUEUED
    /// this work. It runs in an anonymous task nothing can cancel, so it has to
    /// police its own lifetime — and a Boolean cannot: `teardown` sets
    /// `isTornDown`, but a quick Back clears it again, and an instance that
    /// crossed that pair would sail through, take a fresh fetch generation, and
    /// supersede the very `load` the user came back for. Reading `lifecycle` here
    /// instead of at the spawn site would have the same hole one boundary later —
    /// the body does not start until the actor gets round to it.
    private func reconcileOrFail(live: LiveTurn, reason: String?, lifetime: Int) async {
        guard lifetime == lifecycle, liveTurn === live, isTurnActive else { return }
        streamReconnects = 0
        // Retried, because two outcomes are "no answer yet" rather than "the
        // turn is lost": a fetch superseded by a concurrently-loaded history
        // page (the user may scroll up during a live turn), and a re-anchor,
        // which leaves no coordinate system in which to judge this response.
        // Failing on either would announce a dead connection for a turn that is
        // perfectly healthy.
        for attempt in 0..<3 {
            guard lifetime == lifecycle, liveTurn === live, isTurnActive else { return }
            if let id = conversationID,
               case .fetched(let fetch)? = try? await fetchWindowedDetail(id: id),
               liveTurn === live, isTurnActive {
                let detail = fetch.detail
                summary = detail.summary
                sessionStats = detail.sessionStats ?? sessionStats
                // Adopt only a transcript that genuinely advanced past our
                // pre-turn baseline AND ends with a real reply — never a stale
                // read. The baseline is a GLOBAL index, not a loaded count: a
                // windowed response holds only its slice, so counts are not
                // comparable across a window that moved.
                //
                // A re-anchored response is NOT exempt. `turns_total` can have
                // collapsed far below the baseline, so the growth test cannot
                // run — but "cannot judge" is not "accept": a freshly-anchored
                // tail that still ends with the PREVIOUS turn's reply satisfies
                // `transcriptHasReply` just as well, and adopting it would drop
                // the reply we streamed. Retry rather than guess. (See the
                // matching note in `refreshAfterTurn` for why the window is
                // deliberately left stranded rather than rebased here.)
                if !fetch.reanchored,
                   detail.globalEnd > loadedEnd,
                   Self.transcriptHasReply(detail.turns, localRoundFailed: live.failedLocally) {
                    isTurnActive = false
                    clearInteractivePrompts()
                    turns = detail.turns
                    adoptTranscriptScope(detail)
                    pendingUserTurns.removeAll()
                    liveTurn = nil
                    sendState = .idle
                    closeStream()
                    requestScrollToBottom()
                    // The turn is over and the agent free, as after `finalize`.
                    scheduleQueueFlush()
                    return
                }
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        // Ownership is re-checked here, not just inside the loop: the final
        // attempt can end in `.superseded` or a throw, and a second turn may
        // have taken over during that await. Failing `live` then would tear
        // down state the newer turn owns — as would failing it after the user
        // left, which the loop guard alone does not cover (teardown can land
        // during the last attempt).
        guard lifetime == lifecycle, liveTurn === live, isTurnActive else { return }
        turnEndUnconfirmed = true
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
        reconcileDepth += 1
        defer {
            reconcileDepth -= 1
            // Every exit, including the ownership guards that return early: if the
            // obligation outlived this reconcile, someone still has to drain it.
            scheduleReanchorIfIdle()
        }
        // Whether the finished live turn has content worth preserving. If it was
        // empty (e.g. a no-op turn), there's nothing to protect — adopt whatever
        // the server returns on the first successful fetch.
        let mustPreserveReply = !live.isEmpty
        // Pre-turn baseline. A fetched transcript is only "ours" once it has grown
        // past this — otherwise a stale read that still ends with the *previous*
        // turn's assistant reply would satisfy `transcriptHasReply` and we'd adopt
        // it, dropping the reply we just streamed. `turns` isn't mutated elsewhere
        // between finalize and this reconcile.
        //
        // A GLOBAL index, not a loaded count: a windowed response carries only
        // its slice, so `turns.count` is not comparable across responses (and a
        // page loaded during the retry loop grows `turns` without the transcript
        // having advanced at all — the global end is invariant under a prepend).
        let baselineEnd = loadedEnd

        for attempt in 0..<5 {
            // If the user started another turn while we were reconciling, that
            // newer turn now owns turns/pendingUserTurns/liveTurn; bail so we
            // don't wipe its in-flight state (its own finalize reconciles later).
            // Cancellation means the screen is gone (`teardown`) — stop before
            // issuing another request, not merely before committing one.
            guard !Task.isCancelled, liveTurn === live else { return }
            do {
                // `.superseded` (e.g. a history page the user pulled in while
                // this retried) commits nothing and falls through to the backoff
                // so the next attempt re-reads — it is not a failure.
                if case .fetched(let fetch) = try await fetchWindowedDetail(id: id) {
                    let detail = fetch.detail
                    // Re-check after the await — a new turn may have begun during
                    // it, or the screen may have gone.
                    guard !Task.isCancelled, liveTurn === live else { return }
                    // Identity/stats are always safe to adopt, even before the reply
                    // is queryable, so the header stays fresh while we wait.
                    summary = detail.summary
                    sessionStats = detail.sessionStats ?? sessionStats

                    // Adopt only once the transcript has genuinely advanced for THIS
                    // turn: it must have grown past the baseline (so a stale read that
                    // merely ends with an older reply can't masquerade as ours) and —
                    // when there's a streamed reply to protect — end with a non-empty
                    // assistant turn.
                    //
                    // A re-anchored response proves NOTHING about this turn: the
                    // compaction rewrote the coordinates the baseline was captured
                    // in, and the fresh tail can just as easily end with the
                    // PREVIOUS reply — which `transcriptHasReply` would wave
                    // through, and which for an empty live reply isn't even
                    // checked. Keep the live turn and retry; if the budget runs
                    // out, `promoteUnreconciled` below preserves the reply.
                    //
                    // Adopting it mid-loop is not an option either: the rewritten
                    // tail can already contain this round, which would then render
                    // twice, once persisted and once live. The window is therefore
                    // left on retired coordinates for now and repaired below, once
                    // the turn has settled — leaving it retired is what used to
                    // freeze this screen for the rest of the visit.
                    let advanced = !fetch.reanchored && detail.globalEnd > baselineEnd
                    if advanced, !mustPreserveReply
                        || Self.transcriptHasReply(detail.turns, localRoundFailed: live.failedLocally) {
                        turns = detail.turns
                        adoptTranscriptScope(detail)
                        pendingUserTurns.removeAll()
                        liveTurn = nil
                        requestScrollToBottom()
                        return
                    }
                    // Not reconciled for this turn yet — keep the finalized live turn
                    // visible and try again shortly.
                }
            } catch {
                // Re-fetch failed: keep the live turn (now finalized, no pulse) so
                // the user still sees the reply, then retry.
            }
            // Don't sleep after the final attempt.
            if attempt < 4 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Ownership is re-checked here, not only inside the loop: the final
        // attempt can end in `.superseded` or a throw, and sending is re-enabled
        // once a turn finalizes — so a second turn may have taken over during
        // that last await, and this one must touch nothing it now owns.
        guard !Task.isCancelled, liveTurn === live else { return }
        // Gave up reconciling (the server hasn't persisted the reply within the
        // retry window). Fold the finalized reply — and its optimistic user turn —
        // into the authoritative `turns` so it survives a subsequent send instead
        // of living only in the single `liveTurn` slot; a later reconcile or full
        // load replaces it with the server's copy.
        // Promotion moved the round INTO `turns`, which is exactly the state the
        // drain in the `defer` above requires — it runs next and re-anchors if a
        // rewrite retired the window.
        promoteUnreconciled(live)
    }

    /// Start the re-anchor recovery if one is owed and nothing else owns the
    /// transcript right now.
    ///
    /// "Nothing else" includes anything locally synthesized held OUTSIDE `turns`:
    /// an optimistic user turn or a live reply. The recovery replaces `turns`
    /// wholesale with the server's tail, and that tail may already contain the
    /// very round those slots are showing — adopting it underneath them renders
    /// the round twice. Whoever is holding them folds them in first
    /// (`promoteUnreconciled`) or drops them (`discardOptimisticSend`), and the
    /// drain that follows finds this predicate true. Paths that deliberately keep
    /// a finished reply on screen (`cancel`, a failed turn with partial output)
    /// therefore do not re-anchor while it is up; the next settled turn does.
    private func scheduleReanchorIfIdle() {
        guard !isTornDown, windowNeedsReanchor, reconcileDepth == 0,
              liveTurn == nil, pendingUserTurns.isEmpty,
              let id = conversationID else { return }
        reanchorTask?.cancel()
        reanchorTask = Task { [weak self] in await self?.reanchorTranscript(id: id) }
    }

    /// Re-open the transcript at the tail after a rewrite retired the window's
    /// coordinates.
    ///
    /// Every refresh above answered `reanchored`, and a re-anchored response
    /// proves nothing about the turn being reconciled — so none could be adopted.
    /// But refusing them also leaves the window pointing into a prefix the server
    /// has rewritten, and `fetchWindowedDetail` goes on re-anchoring against those
    /// same dead coordinates: without this the screen would keep showing
    /// pre-compaction history, and never update again, for the rest of the visit.
    /// The desktop has no equivalent stall — it commits the fresh tail on every
    /// fingerprint mismatch (`fetchDetailWindowed` in
    /// `conversation-runtime-store.ts`).
    ///
    /// The tail is adopted as-is — nothing locally synthesized is carried onto it.
    /// Appending anything would assume it is newer than everything the tail holds,
    /// and that is not knowable: the round may have persisted while the reconcile
    /// was retrying, and another client may have written after it, so the append
    /// can replay a round after content that already follows it. The cost is that
    /// a round the rewrite did not preserve leaves the screen — which is also the
    /// truthful answer, since a transcript rewritten server-side from what WAS
    /// persisted does not contain it, and reopening the session has always shown
    /// exactly this.
    private func reanchorTranscript(id: Int) async {
        // Retried: a single request is the ONLY thing standing between the user
        // and a transcript that never updates again, and the obligation's `didSet`
        // cannot re-fire (it is already true), so a transient failure here would
        // strand the screen until some later turn happens to drain it.
        for attempt in 0..<3 {
            guard !Task.isCancelled, windowNeedsReanchor, liveTurn == nil else { return }
            // Take a place in the shared order over transcript reads, exactly as
            // `fetchWindowedDetail` does.
            let generation = nextFetchGeneration()
            if let detail = try? await client.conversationDetail(id: id, tailTurns: Self.tailTurns) {
                // Ownership, including the ABA case a boolean re-check cannot see:
                // a whole new round can start AND finish while this request is
                // suspended, leaving `liveTurn` back at nil over a newer
                // transcript.
                guard !Task.isCancelled, liveTurn == nil else { return }
                // Overtaken by another transcript read (a history page the user
                // pulled in, say). Not a failure and NOT a reason to stop: that
                // reader may itself fail, and this is the only task that owes the
                // obligation — dropping out here would strand it. Retry instead;
                // if the winner did adopt, the top-of-loop check sees the
                // obligation already cleared and this exits on its own.
                if isCurrentGeneration(generation) {
                    summary = detail.summary
                    turns = detail.turns
                    adoptTranscriptScope(detail)
                    sessionStats = detail.sessionStats ?? sessionStats
                    requestScrollToBottom()
                    return
                }
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(600)) }
        }
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
        // "Cancelled." message (which `snapshotAsMessageTurns` can't represent as a
        // persisted block, since ContentBlock has no error case) — appending its
        // zero-block snapshot would render as "No content". Such a transient error
        // placeholder is simply dropped on the next send; the user turn is kept.
        turns.append(contentsOf: live.snapshotAsMessageTurns())
        liveTurn = nil
        requestScrollToBottom()
    }

    /// True when the latest persisted turn is an assistant reply that actually
    /// carries renderable content — the signal that the server has committed the
    /// reply we just streamed (vs. only the user turn, or an empty placeholder).
    ///
    /// It also holds when the transcript ends on a FAILED round's line (a
    /// `turn_error` system turn) — but only if the round that just ended here
    /// failed too. Otherwise that line is an EARLIER round's, and the transcript
    /// has not reached this round at all. Mirrors the web's
    /// `parseHoldsTheLatestRound`.
    private static func transcriptHasReply(_ turns: [MessageTurn], localRoundFailed: Bool) -> Bool {
        guard let last = turns.last else { return false }
        if last.isTurnErrorTurn { return localRoundFailed }
        guard last.role == .assistant else { return false }
        return last.blocks.contains { block in
            switch block {
            case .text(let t), .thinking(let t):
                return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .toolUse, .toolResult, .turnError, .unknown:
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
            live.errorIsCancellation = true
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
        // Stopped, the agent is free for the next queued message — once the
        // server has wound the turn down, which this closed stream won't hear
        // about. Wait out one backoff first (a send still landing early just
        // bounces and is retried).
        lastQueueBounceAt = ContinuousClock.now
        scheduleQueueFlush()
        // No re-anchor drain here: the cancelled reply is deliberately left on
        // screen, and the server may have already persisted the same round — so
        // adopting its tail underneath would show that round twice. Nor is one
        // coming from this turn: the stream is closed and `isTurnActive` is false,
        // so no terminal event will reconcile it. It drains on the next turn that
        // either reconciles or rolls back before acceptance — or on reopening.
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
        // Nothing can be retrying on a stream that is gone.
        turnRetry = nil
    }

    /// Tear down all live work — call from `.onDisappear` / deinit paths.
    func teardown() {
        isTornDown = true
        lifecycle &+= 1
        loadTask?.cancel()
        loadTask = nil
        olderTurnsTask?.cancel()
        olderTurnsTask = nil
        piTrustTask?.cancel()
        piTrustTask = nil
        relocationTask?.cancel()
        relocationTask = nil
        sendTask?.cancel()
        sendTask = nil
        queueFlushTask?.cancel()
        queueFlushTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        reanchorTask?.cancel()
        reanchorTask = nil
        // Cancellation stops the reconcile from ISSUING more work; retiring the
        // fetch generation stops anything already in flight — a request suspended
        // when the cancel landed — from committing to a screen the user has left.
        _ = nextFetchGeneration()
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
