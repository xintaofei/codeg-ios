import SwiftUI
import Observation

/// Backs the agent-options sheet: loads the mode/config catalog + current state
/// and applies the user's picks.
///
/// Source of truth is the AUTHORITATIVE live session snapshot
/// (`acp_get_session_snapshot_by_conversation`, injected as `loadSnapshot`), which
/// reflects the real chat session's current mode/config. When no live session
/// exists yet, it falls back to a server-side *probe* agent
/// (`acp_describe_agent_options`) just to enumerate the catalog (its `current_*`
/// are fresh-session defaults). The snapshot query is cheap (no spawn) and the
/// sheet auto-loads it on open; when there's no live session and no cached
/// catalog, it also auto-runs the probe (no manual "Load options" tap).
///
/// Applying targets the live *chat* connection via the injected
/// `resolveConnection` closure (which validates connection liveness — see
/// `SessionDetailViewModel.resolveConnectionForOptions`). Because `set_mode` /
/// `set_config_option` only *enqueue* the change server-side (HTTP 200 ≠ applied),
/// an apply optimistically updates the selection and then RECONCILES by polling
/// the snapshot until it reflects the change (or settles on the agent's
/// normalized value). An HTTP error — including a dead connection — reverts and
/// notices.
@MainActor
@Observable
final class AgentOptionsModel {

    enum Phase: Equatable {
        case idle              // not loaded yet — transient; prepare() auto-loads
        case loading           // probe agent starting
        case loaded            // modes/config available
        case empty             // loaded, but nothing configurable
        case failed(String)
    }

    /// What a selection targets: the session's mode, or one config option by id.
    ///
    /// Typed rather than a `String` with a `"mode"` sentinel, because `"mode"` is
    /// a real config-option id: codex-acp 1.0.0 advertises its approval presets
    /// as BOTH standard ACP modes and an `id = "mode"` config option (see
    /// `ensure_codex_mode_option` in the server's `connection.rs`). Under a
    /// sentinel, picking that option would write the session-mode preference and
    /// leave the config one stale — and at connect the server applies the mode
    /// first and the config values after, so the stale one would win.
    enum Selector: Hashable, Sendable {
        case mode
        case config(id: String)
    }

    private let client: CodegClient

    /// Injected by the owner to resolve (and cache) the shared chat connection.
    var resolveConnection: (() async throws -> String)?

    /// Injected by the owner to fetch the authoritative live session snapshot for
    /// this conversation (nil when no live session exists).
    var loadSnapshot: (() async throws -> SessionSnapshot?)?

    private(set) var phase: Phase = .idle
    private(set) var snapshot: AgentOptionsSnapshot?

    /// Current selection. Authoritative when sourced from the live snapshot; a
    /// fresh-session default when only the probe catalog is available.
    private(set) var selectedModeId: String?
    private(set) var selectedConfig: [String: String] = [:]   // configId → valueId

    /// Selectors being applied FOR THE AGENT ON SCREEN, so a row can spin. Read
    /// from the shared registry, so retargeting the sheet neither strands another
    /// agent's spinner nor drops the claim that operation still holds.
    var applying: Set<Selector> {
        guard let agentType else { return [] }
        return SelectorApplyRegistry.shared.selectors(for: agentType)
    }

    /// Transient apply failure surfaced under the selectors.
    var errorNotice: String?

    /// Catalog cache per agent type so re-opening the sheet doesn't re-spawn a
    /// probe when there's no live session.
    private var cache: [AgentType: AgentOptionsSnapshot] = [:]

    /// The agent the catalog + selection on screen belong to. Read by the
    /// options button so a draft that just switched agents never summarizes the
    /// previous agent's settings under the new agent's icon.
    private(set) var agentType: AgentType?
    private var workingDir: String?
    private var loadTask: Task<Void, Never>?
    /// The cheap auto snapshot-load kicked off on `prepare`.
    private var autoLoadTask: Task<Void, Never>?
    /// The spawn-free load behind the button's summary (``refreshSummary``).
    private var summaryTask: Task<Void, Never>?
    /// Memoized chat-connection resolution, shared across concurrent applies.
    private var connectionTask: Task<String, Error>?

    /// Bounded reconcile poll after an apply (~2.3s total).
    private static let reconcileAttempts = 6

    init(client: CodegClient) {
        self.client = client
    }

    /// Call when the sheet appears. Sets context and auto-loads: a cheap
    /// authoritative snapshot first (no agent spawn) — if a live session exists the
    /// sheet populates immediately; otherwise it shows a cached catalog, or auto-
    /// runs the probe (`load()`) when there's neither.
    func prepare(agentType: AgentType, workingDir: String?) {
        // Switching agents (draft new-session picker) invalidates the previous
        // catalog + selection — clear them so the new agent's options reload clean.
        if let current = self.agentType, current != agentType {
            snapshot = nil
            selectedModeId = nil
            selectedConfig = [:]
            phase = .idle
        }
        self.agentType = agentType
        self.workingDir = workingDir
        errorNotice = nil
        // A new sheet session should re-validate the chat connection (it may have
        // gone stale since last open). Don't cancel — an in-flight apply still
        // holds its own reference to the prior task.
        connectionTask = nil
        if case .failed = phase { phase = .idle }

        // The sheet's own load supersedes a summary refresh still in flight.
        summaryTask?.cancel()
        summaryTask = nil
        autoLoadTask?.cancel()
        autoLoadTask = Task { [weak self] in
            guard let self else { return }
            // 1) Cheap authoritative snapshot first (no agent spawn).
            if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                if Task.isCancelled { return }
                self.cache[agentType] = snap.asOptionsSnapshot
                self.applyAuthoritative(snap)
                return
            }
            if Task.isCancelled { return }
            // 2) No live session — show a previously fetched catalog if we have one
            //    (highlights are defaults, not authoritative).
            if let cached = self.cache[agentType] {
                self.applyCatalog(cached)
                return
            }
            // 3) Otherwise auto-run the probe (formerly the manual "Load options"
            //    tap) so opening the sheet loads the config on its own.
            self.load()
        }
    }

    /// The settings as the button summarizes and the sheet edits them: the
    /// catalog on screen with the current selection laid over it. Empty until a
    /// catalog has loaded.
    func sessionSettings(modeTitle: String) -> [SessionSetting] {
        guard let snapshot else { return [] }
        return SessionSettings.build(
            snapshot: snapshot,
            selectedModeId: selectedModeId,
            selectedConfig: selectedConfig,
            modeTitle: modeTitle
        )
    }

    /// Keep the options button's summary current without opening the sheet.
    ///
    /// Strictly the cheap half of ``prepare(agentType:workingDir:)``: the live
    /// snapshot (polled briefly, since a reattaching session publishes its
    /// selectors a moment after the screen opens), else a catalog this model
    /// already fetched. It NEVER starts a probe agent — the button just shows its
    /// icon until a catalog exists — and never touches the error notice or the
    /// memoized connection, which belong to the sheet.
    ///
    /// The same adopt paths as the sheet, so the selector-preference rules hold
    /// unchanged. Skipped while any apply for this agent is in flight: that
    /// operation owns its selector until it reconciles, and an authoritative
    /// adopt mid-flight would flash the old value back.
    func refreshSummary(agentType: AgentType, workingDir: String?) {
        if let current = self.agentType, current != agentType {
            snapshot = nil
            selectedModeId = nil
            selectedConfig = [:]
            phase = .idle
        }
        self.agentType = agentType
        self.workingDir = workingDir

        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            for delay in Self.summaryPollDelays {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard let self, !Task.isCancelled, self.agentType == agentType else { return }
                if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                    guard !Task.isCancelled, self.agentType == agentType,
                          self.applying.isEmpty else { return }
                    self.cache[agentType] = snap.asOptionsSnapshot
                    self.applyAuthoritative(snap)
                    return
                }
                guard !Task.isCancelled, self.agentType == agentType else { return }
                if let cached = self.cache[agentType] {
                    // The catalog shown before is what the sheet would show too.
                    if self.snapshot == nil, self.applying.isEmpty { self.applyCatalog(cached) }
                    return
                }
            }
        }
    }

    /// When the summary refresh re-reads the live snapshot (~3.5s in all).
    private static let summaryPollDelays: [Duration] = [.zero, .milliseconds(1000), .milliseconds(2500)]

    /// Load the catalog (auto-run by `prepare()`, and by the failure "Try Again").
    /// Prefers the authoritative snapshot (no spawn); only when there's no live
    /// session does it spawn a probe agent to enumerate the catalog (uses the
    /// client's longer probe timeout).
    func load() {
        guard let agentType else { return }
        if case .loading = phase { return }
        errorNotice = nil
        // Neutral loading during the cheap snapshot re-check; switch to the
        // probe-specific phase (`.loading`) only once a probe actually starts, so
        // the "starting an agent" copy never shows for a snapshot/cache result
        // (incl. a "Try Again" where a live session has since appeared).
        phase = .idle
        loadTask?.cancel()
        let workingDir = self.workingDir
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                if Task.isCancelled { return }
                self.cache[agentType] = snap.asOptionsSnapshot
                self.applyAuthoritative(snap)
                return
            }
            if Task.isCancelled { return }
            self.phase = .loading   // no live selectors — a probe agent is now starting
            do {
                let probe = try await self.client.describeAgentOptions(agentType: agentType, workingDir: workingDir)
                if Task.isCancelled { return }
                self.cache[agentType] = probe
                self.applyCatalog(probe)
            } catch is CancellationError {
                // superseded / torn down
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    private func fetchSnapshot() async throws -> SessionSnapshot? {
        guard let loadSnapshot else { return nil }
        return try await loadSnapshot()
    }

    /// Adopt authoritative current mode/config from the live snapshot (overwrites
    /// any optimistic selection — the snapshot IS the truth).
    private func applyAuthoritative(_ snap: SessionSnapshot) {
        let options = snap.asOptionsSnapshot
        snapshot = options
        selectedModeId = snap.modes?.currentModeId ?? snap.currentMode ?? selectedModeId
        for option in snap.configOptions ?? [] {
            if let current = option.kind.currentValueString, !current.isEmpty {
                selectedConfig[option.id] = current
            }
        }
        dropRejectedPreferences(in: snap.configOptions ?? [], modes: snap.modes)
        phase = options.isEmpty ? .empty : .loaded
    }

    /// Adopt a probe catalog (no live session — drafts / fresh agents). Seed
    /// selections, only where the user hasn't already picked, preferring the
    /// LOCALLY CACHED last-used choice (validated against this catalog) and
    /// falling back to the catalog's fresh-session default. This is what makes a
    /// new session's options sheet open on the user's remembered mode/config.
    private func applyCatalog(_ snap: AgentOptionsSnapshot) {
        snapshot = snap
        let prefs = agentType.map { SelectorPrefsStore.prefs(for: $0) } ?? SelectorPrefs()
        if selectedModeId == nil {
            if let saved = prefs.modeId,
               snap.modes?.availableModes.contains(where: { $0.id == saved }) == true {
                selectedModeId = saved
            } else {
                selectedModeId = snap.modes?.currentModeId
            }
        }
        for option in snap.configOptions where selectedConfig[option.id] == nil {
            if let saved = prefs.configValues?[option.id], option.kind.accepts(saved) {
                selectedConfig[option.id] = saved
            } else if let current = option.kind.currentValueString, !current.isEmpty {
                selectedConfig[option.id] = current
            }
        }
        dropRejectedPreferences(in: snap.configOptions, modes: snap.modes)
        phase = snap.isEmpty ? .empty : .loaded
    }

    /// Forget any remembered value this agent's CURRENT catalog says it can't
    /// take, so the sheet and the next `acp_connect` agree.
    ///
    /// Declining to highlight a rejected value isn't enough on its own: the whole
    /// preference map is replayed at connect, unvalidated. An option that changed
    /// kind between agent versions is the case that bites — a select's `"on"`
    /// left over on what is now a boolean isn't rejected server-side, it's read
    /// as "not `\"true\"`" and applied as OFF, against a sheet showing the agent's
    /// own (possibly ON) value.
    ///
    /// Only options present in this catalog are judged. A value for an option the
    /// agent no longer advertises is left alone: it may belong to an agent version
    /// the user goes back to. Note this is NOT because the server would ignore it
    /// — `apply_preferred_selectors` deliberately forwards an unadvertised
    /// `config_id` and lets the agent decide (codex-acp accepts `"mode"` whether
    /// or not it advertised it) — but because a value we cannot judge is not one
    /// we should throw away.
    /// A selector with an apply in flight is skipped: that operation owns the
    /// entry until it settles, and it is judging against the connection it
    /// targeted rather than against this catalog.
    /// Judge just the one selector that finished applying, against the catalog on
    /// screen. Deliberately NOT the whole sweep: this catalog may be older than
    /// some other selector's freshly settled value, and for Grok it can be a
    /// different catalog entirely — switching model replaces the reasoning-effort
    /// selector wholesale — so a broad re-judgement could delete a preference that
    /// is perfectly valid under the catalog it was chosen from.
    private func revalidate(_ selector: Selector, agent: AgentType) {
        guard agentType == agent, let snapshot else { return }
        let saved = SelectorPrefsStore.prefs(for: agent)
        switch selector {
        case .mode:
            guard let value = saved.modeId, let modes = snapshot.modes,
                  !modes.availableModes.isEmpty,
                  !modes.availableModes.contains(where: { $0.id == value }) else { return }
            remember(.mode, value: nil, agent: agent)
        case .config(let id):
            guard let value = saved.configValues?[id],
                  let option = snapshot.configOptions.first(where: { $0.id == id }),
                  option.kind.isRenderable, !option.kind.accepts(value) else { return }
            remember(selector, value: nil, agent: agent)
        }
    }

    private func dropRejectedPreferences(in options: [SessionConfigOption], modes: SessionModeState?) {
        guard let agent = agentType else { return }
        let saved = SelectorPrefsStore.prefs(for: agent)

        if let remembered = saved.modeId, let modes, !modes.availableModes.isEmpty,
           !modes.availableModes.contains(where: { $0.id == remembered }),
           !SelectorApplyRegistry.shared.isClaimed(.init(agent: agent, selector: .mode)) {
            remember(.mode, value: nil, agent: agent)
        }

        guard let savedConfig = saved.configValues else { return }
        for option in options where option.kind.isRenderable {
            let selector = Selector.config(id: option.id)
            guard let value = savedConfig[option.id], !option.kind.accepts(value),
                  !SelectorApplyRegistry.shared.isClaimed(.init(agent: agent, selector: selector))
            else { continue }
            remember(selector, value: nil, agent: agent)
        }
    }

    // MARK: - Apply

    /// Apply `value` to whichever selector a ``SessionSetting`` targets.
    func apply(_ selector: Selector, value: String) {
        switch selector {
        case .mode: selectMode(value)
        case .config(let id): selectConfig(optionId: id, valueId: value)
        }
    }

    func selectMode(_ modeId: String) {
        guard modeId != selectedModeId, let agent = agentType, canApply(.mode, agent: agent) else { return }
        let previous = selectedModeId
        selectedModeId = modeId   // optimistic (only after the guards pass)
        // Remember the pick per agent so the next new session starts in this mode
        // (re-applied via acp_connect's preferredModeId). Mirrors the web client.
        remember(.mode, value: modeId, agent: agent)
        run(selector: .mode, desired: modeId, previous: previous, agent: agent) { client, conn in
            try await client.setMode(connectionId: conn, modeId: modeId)
        }
    }

    func selectConfig(optionId: String, valueId: String) {
        let selector = Selector.config(id: optionId)
        guard selectedConfig[optionId] != valueId, let agent = agentType,
              canApply(selector, agent: agent) else { return }
        let previous = selectedConfig[optionId]
        selectedConfig[optionId] = valueId   // optimistic (only after the guards pass)
        remember(selector, value: valueId, agent: agent)
        run(selector: selector, desired: valueId, previous: previous, agent: agent) { client, conn in
            try await client.setConfigOption(connectionId: conn, configId: optionId, valueId: valueId)
        }
    }

    /// Persist (or forget, for a nil value) one remembered selection.
    ///
    /// This has to move in lockstep with the visible selection, including on the
    /// revert path: the remembered value is replayed on the NEXT `acp_connect`
    /// as `preferredConfigValues`/`preferredModeId`, so a value left behind by a
    /// failed apply silently takes effect later, in a session where the user
    /// never sees it. That is merely surprising for a model pick and unacceptable
    /// for cline's `auto_approve`, whose whole job is to stop asking before
    /// running a tool.
    ///
    /// `agent` is passed rather than read from `agentType`: an apply outlives the
    /// draft's agent picker, and its outcome belongs to the agent it was made
    /// for, not to whichever one the sheet is showing when it lands.
    private func remember(_ selector: Selector, value: String?, agent: AgentType) {
        switch selector {
        case .mode:
            SelectorPrefsStore.saveMode(agent: agent, modeId: value)
        case .config(let id):
            SelectorPrefsStore.saveConfig(agent: agent, configId: id, valueId: value)
        }
    }

    /// True when an apply for `selector` can start: a connection resolver is wired
    /// and no apply for the same selector is already in flight — so a rapid/second
    /// tap can't move the highlighted selection without sending a matching network
    /// command.
    private func canApply(_ selector: Selector, agent: AgentType) -> Bool {
        resolveConnection != nil
            && !SelectorApplyRegistry.shared.isClaimed(.init(agent: agent, selector: selector))
    }

    private func run(
        selector: Selector,
        desired: String,
        previous: String?,
        agent: AgentType,
        action: @escaping (CodegClient, String) async throws -> Void
    ) {
        guard resolveConnection != nil else {
            revert(selector, to: previous, agent: agent)
            return
        }
        let claim = SelectorApplyRegistry.Claim(agent: agent, selector: selector)
        SelectorApplyRegistry.shared.claim(claim)
        errorNotice = nil
        let client = self.client
        Task { [weak self] in
            // Established BEFORE the weak-self exit and independent of the model:
            // the claim is process-wide, so a model torn down before this job got
            // a reference would otherwise strand that (agent, selector) for the
            // life of the process.
            defer { SelectorApplyRegistry.shared.release(claim) }
            guard let self else { return }
            var resolution: Task<String, Error>?
            do {
                let shared = try self.sharedConnection()
                resolution = shared
                let conn = try await shared.value
                try await action(client, conn)
                // Drop the memoized resolution so the NEXT apply re-validates the
                // connection's liveness (only concurrent in-flight applies, which
                // already hold this task, share one resolve).
                self.retire(shared)
                // HTTP 200 only means the command was enqueued — reconcile against
                // the authoritative snapshot of the EXACT connection we targeted
                // (by id, so it works even before the connection binds to the
                // conversation) before trusting the optimistic value.
                await self.reconcile(selector: selector, desired: desired, connectionId: conn, agent: agent)
            } catch is CancellationError {
                self.revert(selector, to: previous, agent: agent)
                self.retire(resolution)
            } catch {
                self.revert(selector, to: previous, agent: agent)
                self.retire(resolution)   // re-resolve on the next apply
                if self.agentType == agent { self.errorNotice = Self.describe(error) }
            }
            // A catalog load that happened WHILE the claim was held skipped this
            // entry on purpose. Judge it once now that the operation has settled,
            // or a value the loaded catalog rejects could sit in the store until
            // some later load happens along. The claim is released by the `defer`
            // above — which runs after this, so lift the judgement out of the
            // skip-if-claimed rule explicitly.
            self.revalidate(selector, agent: agent)
        }
    }

    /// Undo an apply that didn't take. The STORE is put back regardless of what
    /// the sheet is showing now — that entry belongs to `agent` and is replayed at
    /// its next connect. It is the sole owner of that entry (see
    /// ``SelectorApplyRegistry``), so no check is needed. The visible selection is
    /// only restored while the sheet is still on that agent — otherwise it belongs
    /// to whatever is on screen now.
    private func revert(_ selector: Selector, to previous: String?, agent: AgentType) {
        remember(selector, value: previous, agent: agent)
        guard agentType == agent else { return }
        switch selector {
        case .mode: selectedModeId = previous
        case .config(let id): selectedConfig[id] = previous
        }
    }

    /// Resolve the chat connection once and share it across concurrent applies, so
    /// a rapid mode+config change can't each resolve a different connection (which
    /// would strand one setting on an orphan). The model is `@MainActor`, so the
    /// synchronous prologue here is race-free: the first caller installs the task,
    /// later callers await the same one. Cleared after each apply (so the next one
    /// re-validates liveness) and on (re)prepare / teardown.
    ///
    /// Hands back the task rather than its value so the caller can retire exactly
    /// the resolution it used — see ``retire(_:)``.
    private func sharedConnection() throws -> Task<String, Error> {
        if let task = connectionTask { return task }
        guard let resolveConnection else { throw APIError.transport("Session closed.") }
        let task = Task { try await resolveConnection() }
        connectionTask = task
        return task
    }

    /// Retire a memoized resolution — but only while it is still the one this
    /// apply used.
    ///
    /// An apply outlives the sheet that started it. `prepare()` (reopened, or
    /// retargeted at another agent) installs a fresh memo, and so does any later
    /// apply; clearing one of those on the way out would send the next selector
    /// off to resolve on its own, which on a draft means a second agent process
    /// with this apply's setting left behind on the first.
    private func retire(_ used: Task<String, Error>?) {
        guard let used, connectionTask == used else { return }
        connectionTask = nil
    }

    /// Poll the authoritative snapshot of the targeted connection until it confirms
    /// `desired` for `selector`, or it settles on a different (agent-normalized)
    /// value, or we time out. Adopts the authoritative value when seen; otherwise
    /// keeps the optimistic pick. Queries by `connectionId` so it works even before
    /// the connection is bound to the conversation.
    private func reconcile(selector: Selector, desired: String, connectionId: String,
                           agent: AgentType) async {
        var lastSeen: (value: String, accepted: Bool?)?
        for attempt in 0..<Self.reconcileAttempts {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 400))
            if Task.isCancelled { return }
            guard let snap = try? await client.connectionSnapshot(connectionId: connectionId) else { continue }
            guard let current = currentValue(for: selector, in: snap) else {
                // A snapshot that answered but no longer carries this selector
                // retires the older evidence rather than letting it be adopted
                // from stale grounds.
                lastSeen = nil
                continue
            }
            let seen = (value: current, accepted: accepts(selector, current, in: snap))
            lastSeen = seen
            if current == desired {
                adopt(selector, seen, agent: agent)   // confirmed
                return
            }
        }
        // Settled without confirming the pick — adopt the last authoritative value
        // we saw (the agent may have normalized/rejected it); if we never saw one,
        // keep the optimistic pick as a best effort.
        if let lastSeen { adopt(selector, lastSeen, agent: agent) }
    }

    private func currentValue(for selector: Selector, in snap: SessionSnapshot) -> String? {
        switch selector {
        case .mode:
            return snap.modes?.currentModeId ?? snap.currentMode
        case .config(let id):
            return snap.configOptions?.first { $0.id == id }?.kind.currentValueString
        }
    }

    /// Adopt an AUTHORITATIVE value seen during reconciliation.
    ///
    /// What the agent holds beats what was asked for on SCREEN — but not in the
    /// store. The remembered value is what the next session starts from, and an
    /// agent reverting a pick in THIS session doesn't mean the user stopped
    /// wanting it: Grok makes that explicit, refusing an incompatible in-place
    /// model switch, snapping the live selector back, and deliberately keeping the
    /// attempted model as the preference so the "start a new session" it suggests
    /// actually lands on it (`set_grok_config_option`; the web asserts this in
    /// `acp-connections-context.test.tsx`). So the optimistic write stands.
    ///
    /// The one exception is a value the connection's own catalog says it cannot
    /// take (`accepted == false`) — an agent that normalizes to `""`. That isn't a
    /// preference, it's noise, and connect would replay it verbatim.
    private func adopt(_ selector: Selector, _ seen: (value: String, accepted: Bool?), agent: AgentType) {
        if seen.accepted == false { remember(selector, value: nil, agent: agent) }
        guard agentType == agent else { return }
        switch selector {
        case .mode: selectedModeId = seen.value
        case .config(let id): selectedConfig[id] = seen.value
        }
    }

    /// Whether the TARGETED CONNECTION says `value` is a choice `selector` can
    /// take — nil when there is nothing to judge against: no entry for it (the
    /// server forwards an unadvertised config id and lets the agent decide), or an
    /// option kind this build can't read choices out of. Unjudgeable is not
    /// rejected.
    ///
    /// Judged against the polled snapshot rather than the sheet's `snapshot`,
    /// because the sheet may since have been retargeted at a different agent — one
    /// whose catalog can have an identically-named option with entirely different
    /// values, and has no say over this apply.
    private func accepts(_ selector: Selector, _ value: String, in snap: SessionSnapshot) -> Bool? {
        switch selector {
        case .mode:
            guard let modes = snap.modes, !modes.availableModes.isEmpty else { return nil }
            return modes.availableModes.contains { $0.id == value }
        case .config(let id):
            guard let option = snap.configOptions?.first(where: { $0.id == id }),
                  option.kind.isRenderable else { return nil }
            return option.kind.accepts(value)
        }
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        autoLoadTask?.cancel()
        autoLoadTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        // Deliberately does NOT retire in-flight applies: those operations really
        // are still running, and each still owns its agent's stored preference.
        // Whether one may also touch the VISIBLE selection is decided when it
        // lands, by asking whether the sheet is still on that agent — see
        // ``revert(_:to:agent:)``.
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}

/// Process-wide registry of in-flight selector applies.
///
/// The scope is the point. ``SelectorPrefsStore`` is a process-global blob keyed
/// by agent, and an apply now writes it LONG after the user's tap — when
/// reconciliation settles, or when a failure reverts. The app allows multiple
/// scenes (`UIApplicationSupportsMultipleScenes`), so two session sheets can sit
/// on the same agent; a claim narrower than the store would let the older scene's
/// late write land on top of the newer scene's settled choice.
///
/// So: at most one unsettled apply per (agent, selector) IN THE PROCESS. Every
/// holder is `@MainActor`, which is what makes the check-then-claim atomic.
/// `@Observable` rather than a bare static so the rows watching it still redraw —
/// including the other scene's, which is the honest picture of what's happening.
@MainActor
@Observable
final class SelectorApplyRegistry {
    static let shared = SelectorApplyRegistry()

    struct Claim: Hashable, Sendable {
        let agent: AgentType
        let selector: AgentOptionsModel.Selector
    }

    private(set) var claims: Set<Claim> = []

    private init() {}

    func isClaimed(_ claim: Claim) -> Bool { claims.contains(claim) }
    func claim(_ claim: Claim) { claims.insert(claim) }
    func release(_ claim: Claim) { claims.remove(claim) }

    /// Selectors claimed for `agent`, so its rows can spin.
    func selectors(for agent: AgentType) -> Set<AgentOptionsModel.Selector> {
        Set(claims.lazy.filter { $0.agent == agent }.map(\.selector))
    }
}
