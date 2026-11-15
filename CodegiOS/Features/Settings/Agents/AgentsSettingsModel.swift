import SwiftUI
import Observation

/// Loads + manages the server's agents. The list supports drag-reorder; the
/// detail edits enabled + env vars + model-provider link via the single
/// `acp_update_agent_env` call (which replaces all three together — so each
/// write must carry the agent's current env).
@MainActor
@Observable
final class AgentsSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var agents: [AcpAgentInfo] = []
    var refreshError: String?
    var toast: String?
    /// Agents whose instant enable/disable write is in flight (disables the
    /// toggle so a double-tap can't race two writes).
    private(set) var togglingEnabled: Set<AgentType> = []
    /// Agents with an install/upgrade/uninstall in flight (drives the detail's
    /// progress state + a per-agent reentrancy guard).
    private(set) var installing: Set<AgentType> = []

    private let client: CodegClient?

    /// Tail of a serial chain that ALL agent round-trips (load + enable/env writes)
    /// append to, so they run in call order and never interleave: a refresh can't
    /// land a stale snapshot over a confirmed toggle, and a quick toggle's
    /// persisted-env write can't clobber a concurrent Save's edited env. Reorder
    /// touches a different field (`sort_order`) and keeps its own coalescing sender.
    private var opTail: Task<Void, Never> = Task {}

    /// A trivial `Error` carrying just a message (Task results must be `Sendable`,
    /// and `any Error` isn't), so a serialized `update` can relay its failure.
    private struct OpError: LocalizedError { let message: String; var errorDescription: String? { message } }

    init(client: CodegClient?) { self.client = client }

    func load() async {
        let prior = opTail
        let task = Task { @MainActor in
            await prior.value
            await self.loadBody()
        }
        opTail = task
        await task.value
    }

    private func loadBody() async {
        guard let client else { phase = .failed("No server selected."); return }
        if agents.isEmpty { phase = .loading }
        do {
            agents = try await client.listAgents().sorted { $0.sortOrder < $1.sortOrder }
            // Free refresh of the custom-agent name/icon cache the session rows and
            // timeline avatars read from — this page's list is the authoritative one.
            CustomAgentRegistry.shared.ingest(agents)
            phase = .loaded
            refreshError = nil
        } catch {
            if agents.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = error.localizedDescription }
        }
    }

    /// Detail save — enabled + full env + provider in one call. Serialized with
    /// toggles so the two can't issue overlapping `updateAgentEnv` writes. Throws
    /// so the detail can surface its own error; on success the list reloads.
    func update(_ agent: AcpAgentInfo, enabled: Bool, env: [String: String], modelProviderId: Int?) async throws {
        let prior = opTail
        let task = Task { @MainActor () -> String? in
            await prior.value
            guard let client = self.client else { return nil }
            do {
                let affected = try await client.updateAgentEnv(agentType: agent.agentType, enabled: enabled, env: env, modelProviderId: modelProviderId)
                self.surfaceAffected(affected)
                await self.loadBody()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        opTail = Task { @MainActor in _ = await task.value }
        if let message = await task.value { throw OpError(message: message) }
    }

    /// Live accessor for the detail, which navigates by agent type and reads fresh
    /// data after a save/install reload rather than holding a stale push snapshot.
    func agent(_ agentType: AgentType) -> AcpAgentInfo? {
        agents.first { $0.agentType == agentType }
    }

    /// Full structured save: enabled + flat env + provider via `acp_update_agent_env`,
    /// then — strictly AFTER (codex needs it; safe for all) — the native config via
    /// `acp_update_agent_config`. Serialized on `opTail` so it can't interleave with
    /// an enable toggle; reads the LIVE `enabled` at its slot; surfaces ONE
    /// affected-sessions toast (max of the two calls). Hermes saves via its own path.
    func saveAgentConfig(_ agentType: AgentType, draft: AgentDraft) async throws {
        let prior = opTail
        let task = Task { @MainActor () -> String? in
            await prior.value
            guard let client = self.client,
                  let original = self.agents.first(where: { $0.agentType == agentType }) else { return nil }
            // Reject an unparseable native-config edit BEFORE any write — otherwise a
            // merge agent would diff against `[:]` and emit a destructive delete-all.
            if let parseError = JSONConfig.parse(draft.configText).error { return parseError }
            // Enforce the linked-provider scrub at SAVE time (not just on a structured
            // edit) so opening a linked agent and pressing Save can't re-emit stale
            // provider-managed secrets.
            var payload = draft
            if payload.modelProviderId != nil { payload.reapply(agentType) }
            let liveEnabled = original.enabled
            do {
                let envMap = EnvText.parse(payload.envText)
                let affectedEnv = try await client.updateAgentEnv(
                    agentType: agentType, enabled: liveEnabled,
                    env: envMap, modelProviderId: payload.modelProviderId)
                // A user-registered ACP agent has no config file for the server to
                // write (`agent_local_config_path` returns None for it), and its
                // editor surfaces the environment only — so the env write above is
                // the whole save. Skip the second call rather than posting an
                // all-nil body at an endpoint that has nothing to do with it.
                guard agentType.isBuiltin else {
                    self.surfaceAffected(affectedEnv)
                    await self.loadBody()
                    return nil
                }
                let body = self.makeConfigBody(agentType, draft: payload, original: original)
                let affectedConfig: Int
                do {
                    affectedConfig = try await client.updateAgentConfig(body)
                } catch {
                    // The two writes are not one transaction. For an agent whose env
                    // and native config are two halves of ONE permission decision, a
                    // half-applied save is worse than a failed one: Cursor's "Run
                    // Everything" rides the env while its deny rules live in
                    // cli-config.json, so a rejected config write (e.g. hand-edited
                    // invalid JSON under Advanced) would otherwise leave commands
                    // auto-approved with the new rules never applied. Put the env back
                    // exactly as it was, then report the original failure. Mirrors the
                    // web Cursor panel's explicit rollback.
                    if agentType == .cursor, let previousEnv = original.env {
                        _ = try? await client.updateAgentEnv(
                            agentType: agentType, enabled: liveEnabled,
                            env: previousEnv, modelProviderId: original.modelProviderId)
                    }
                    throw error
                }
                self.surfaceAffected(max(affectedEnv, affectedConfig))
                await self.loadBody()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        opTail = Task { @MainActor in _ = await task.value }
        if let message = await task.value { throw OpError(message: message) }
    }

    /// Build the `acp_update_agent_config` payload, applying the per-type save rules
    /// (codex → toml+auth; open_code → never-null "{}" + auth.json; merge agents →
    /// markRemovedKeysNull against the stored config; others → replace).
    private func makeConfigBody(_ agentType: AgentType, draft: AgentDraft, original: AcpAgentInfo) -> UpdateAgentConfigBody {
        var body = UpdateAgentConfigBody(agentType: agentType)
        switch agentType {
        case .codex:
            let normalized = JSONConfig.normalize(draft.configText)
            body.configJson = normalized.isEmpty ? nil : normalized
            // Enforce the disable_response_storage invariant even if the user edited
            // it out in the raw TOML editor.
            body.codexConfigToml = AgentTOML.setRootBool(draft.codexConfigTomlText, "disable_response_storage", true)
            body.codexAuthJson = draft.codexAuthJsonText
        case .openCode:
            let withNpm = AgentConfig.ensureOpenCodeProviderNpm(draft.configText)
            let normalized = JSONConfig.normalize(withNpm)
            body.configJson = normalized.isEmpty ? "{}" : normalized
            // Empty auth → "{}" (replace the file with an empty object) so cleared
            // provider secrets are actually removed, not left untouched by a null.
            body.opencodeAuthJson = draft.openCodeAuthJsonText.isEmpty ? "{}" : draft.openCodeAuthJsonText
        case .grok:
            // Grok has no config.json (leave configJson nil). The structured
            // controls always go; the raw toml only when the user edited it, so the
            // backend merges the controls onto FRESH on-disk config in the common
            // case (web `buildGrokSaveOptions`). `""` clears a control's key.
            body.grokStructured = GrokStructuredConfig(
                permissionMode: draft.grokPermissionMode.isEmpty ? nil : draft.grokPermissionMode,
                defaultReasoningEffort: draft.grokReasoningEffort.isEmpty ? nil : draft.grokReasoningEffort)
            if draft.grokConfigTomlText != (original.grokConfigToml ?? "") {
                body.grokConfigToml = draft.grokConfigTomlText
            }
        case .cursor:
            // Same split as Grok: Cursor has no config.json, the structured patch
            // always goes, and the raw cli-config.json only when the user edited it
            // — otherwise the backend merges the rules onto the FRESH on-disk file
            // instead of a snapshot the Cursor CLI's own `/config` UI may have
            // moved on from. `""` sandbox means "leave sandbox.mode alone"; the rule
            // lists are replaced wholesale, so an emptied list is sent as `[]`.
            body.cursorStructured = CursorStructuredConfig(
                sandboxMode: draft.cursorSandboxMode.isEmpty ? nil : draft.cursorSandboxMode,
                permissionsAllow: draft.cursorAllowRules.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                permissionsDeny: draft.cursorDenyRules.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
            if draft.cursorCliConfigText != (original.cursorCliConfigJson ?? "") {
                body.cursorCliConfigJson = draft.cursorCliConfigText
            }
        default:
            var configForPersist = JSONConfig.normalize(draft.configText)
            if AgentConfig.usesMerge(agentType) {
                // Mark removed keys null against the STORED config so deletions (incl.
                // emptying the whole config) actually delete on disk — run it whenever
                // the original was non-empty, even if the edited config is now empty.
                let originalConfig = original.configJson.map { JSONConfig.parse($0).config } ?? [:]
                if !originalConfig.isEmpty {
                    let current = JSONConfig.parse(draft.configText).config
                    configForPersist = JSONConfig.serialize(
                        JSONConfig.markRemovedKeysNull(original: originalConfig, current: current))
                }
            }
            body.configJson = configForPersist.isEmpty ? nil : configForPersist
        }
        return body
    }

    /// Save Hermes via its dedicated endpoint, then reload so the caller can rebuild
    /// the draft from the fresh backend projection (structured + raw are two views
    /// of the same data — never trust the stale local draft after a save).
    func saveHermesConfig(_ body: UpdateHermesConfigBody) async throws {
        let prior = opTail
        let task = Task { @MainActor () -> String? in
            await prior.value
            guard let client = self.client else { return nil }
            do {
                try await client.updateHermesConfig(body)
                await self.loadBody()
                return nil
            } catch { return error.localizedDescription }
        }
        opTail = Task { @MainActor in _ = await task.value }
        if let message = await task.value { throw OpError(message: message) }
    }

    /// Save Kimi Code via its dedicated endpoint (apikey/login/raw), then reload so
    /// the gate-status banner + `configJson` projection reflect the fresh backend
    /// state. Serialized on `opTail` (like Hermes) so it can't race a toggle.
    /// `reasoning` is the panel's reasoning card; its untouched fields go out as
    /// they are on disk.
    func saveKimiCodeConfig(_ body: UpdateKimiCodeConfigBody, reasoning: KimiReasoningEdit? = nil) async throws {
        let prior = opTail
        let task = Task { @MainActor () -> String? in
            await prior.value
            guard let client = self.client else { return nil }
            do {
                // An `apikey` save rebuilds the managed model block, so it has to
                // carry every reasoning field the card didn't change. Read them
                // from the LIVE projection right before the write (not the
                // panel's snapshot), and before anything is written, so a failed
                // read aborts with nothing persisted instead of wiping them.
                var payload = body
                if body.mode == "apikey" {
                    let fresh = try await client.listAgents().first { $0.agentType == .kimiCode }
                    do {
                        payload = try kimiBodyForSave(body, reasoning: reasoning, freshConfigJson: fresh?.configJson)
                    } catch {
                        // The card's edit collides with a change made elsewhere.
                        // Nothing is written; reload so the card re-seeds from
                        // what is on disk now, or every retry would collide again.
                        await self.loadBody()
                        throw error
                    }
                }
                let affected = try await client.updateKimiCodeConfig(payload)
                self.surfaceAffected(affected)
                await self.loadBody()
                return nil
            } catch { return error.localizedDescription }
        }
        opTail = Task { @MainActor in _ = await task.value }
        if let message = await task.value { throw OpError(message: message) }
    }

    /// Install / upgrade / uninstall. Awaits the (blocking) server call, then
    /// reconciles version state. Serialized on `opTail`; per-agent reentrancy guard.
    /// `customVersion` is a validated free-text version (upgrade-with-override).
    @discardableResult
    func runInstall(_ agentType: AgentType, _ action: AgentInstallAction, customVersion: String? = nil) async -> Bool {
        guard client != nil, !installing.contains(agentType) else { return false }
        installing.insert(agentType)
        let prior = opTail
        let task = Task { @MainActor () -> Bool in
            await prior.value
            guard let client = self.client,
                  let agent = self.agents.first(where: { $0.agentType == agentType }) else { return false }
            let didClearCache = action.isUpgrade || customVersion != nil
            do {
                let taskId = UUID().uuidString
                var expected: String? = nil   // the version we expect detect to report
                switch action {
                case .downloadBinary, .upgradeBinary:
                    if didClearCache { try await client.clearBinaryCache(agentType: agentType) }
                    try await client.downloadAgentBinary(agentType: agentType, taskId: taskId, version: customVersion)
                    expected = customVersion ?? agent.registryVersion
                case .installNpx, .upgradeNpx:
                    let installed = try await client.prepareNpxAgent(
                        agentType: agentType, registryVersion: agent.registryVersion,
                        taskId: taskId, cleanFirst: action == .upgradeNpx, version: customVersion)
                    expected = customVersion ?? (installed.isEmpty ? agent.registryVersion : installed)
                case .uninstallBinary, .uninstallNpx:
                    try await client.uninstallAgent(agentType: agentType, taskId: taskId)
                case .customInstall:
                    return false   // resolved by the caller to upgrade* + customVersion
                }
                await self.reconcileAfterInstall(agentType, uninstall: action.isUninstall, expected: expected)
                self.toast = action.isUninstall ? "Removed \(agent.name)." : "\(agent.name) is ready."
                return true
            } catch {
                // A failed upgrade/custom-install may have cleared a working binary —
                // re-detect so the UI doesn't show a phantom installed version.
                if didClearCache { await self.reconcileAfterInstall(agentType, uninstall: false, expected: nil) }
                self.refreshError = error.localizedDescription
                return false
            }
        }
        opTail = Task { @MainActor in _ = await task.value }
        let ok = await task.value
        installing.remove(agentType)
        return ok
    }

    /// Install the `uv` runtime (the `install_uv` preflight fix for uvx agents).
    @discardableResult
    func runUvInstall(_ agentType: AgentType) async -> Bool {
        guard client != nil, !installing.contains(agentType) else { return false }
        installing.insert(agentType)
        let prior = opTail
        let task = Task { @MainActor () -> Bool in
            await prior.value
            guard let client = self.client else { return false }
            do {
                try await client.installUvTool(taskId: UUID().uuidString)
                await self.reconcileAfterInstall(agentType, uninstall: false, expected: nil)
                self.toast = "uv runtime installed."
                return true
            } catch {
                self.refreshError = error.localizedDescription
                return false
            }
        }
        opTail = Task { @MainActor in _ = await task.value }
        let ok = await task.value
        installing.remove(agentType)
        return ok
    }

    /// After an install resolves, confirm the end-state. The server call already
    /// blocks until done, so the first detect normally returns the final version
    /// and we break immediately; the bounded poll only matters if a handler ever
    /// returns early. Then reload the list so the version row reflects reality.
    private func reconcileAfterInstall(_ agentType: AgentType, uninstall: Bool, expected: String?) async {
        guard let client = self.client else { return }
        for attempt in 0..<8 {
            let version: String? = (try? await client.detectAgentLocalVersion(agentType: agentType)) ?? nil
            let reached: Bool
            if uninstall {
                reached = version == nil || version?.isEmpty == true
            } else if let expected, AgentVersion.hasComparable(expected) {
                // Wait for the SPECIFIC version (an upgrade's first read can return the
                // old version before the install lands).
                reached = AgentVersion.hasComparable(version) && AgentVersion.compare(version ?? "", expected) == 0
            } else {
                reached = version != nil && version?.isEmpty == false
            }
            if reached { break }
            if attempt < 7 { try? await Task.sleep(for: .seconds(1.5)) }
        }
        await self.loadBody()
    }

    /// Outcome of an instant enable/disable, so a caller with its own optimistic
    /// state (the detail toggle) can tell a real success from a no-op (a write was
    /// already in flight, or the agent vanished) and revert if nothing happened.
    enum ToggleOutcome: Sendable {
        case applied
        case noChange
        case failed(String)
    }

    /// Instant enable/disable (the list row + detail toggle). Flips just `enabled`
    /// while preserving the agent's *persisted* env + provider (so a quick toggle
    /// never commits an unsaved env draft). Runs inside the serial chain, so the
    /// optimistic write + reconcile happen atomically relative to any `load()` or
    /// Save — no stale snapshot or env clobber. Reconciles by id (never a captured
    /// index). Mirrors the web's instant enable switch.
    func setEnabled(_ agent: AcpAgentInfo, _ enabled: Bool) async -> ToggleOutcome {
        guard client != nil else { return .failed("No server selected.") }
        // Reentrancy guard (the toggle is also disabled in-flight in the UI).
        guard !togglingEnabled.contains(agent.agentType),
              agents.contains(where: { $0.id == agent.id }) else { return .noChange }
        togglingEnabled.insert(agent.agentType)
        let prior = opTail
        let task = Task { @MainActor () -> ToggleOutcome in
            await prior.value
            guard let client = self.client,
                  let index = self.agents.firstIndex(where: { $0.id == agent.id }) else { return .noChange }
            // Read the agent's CURRENT persisted env/provider at this chain slot —
            // a preceding Save's reload may have changed them since this toggle was
            // enqueued from a (possibly stale) row/detail snapshot. Sending the
            // captured `agent.env` could overwrite a just-saved env; sending the
            // live values flips only `enabled`.
            let current = self.agents[index]
            let previous = current.enabled
            self.agents[index].enabled = enabled   // optimistic, at this slot in the chain
            do {
                let affected = try await client.updateAgentEnv(
                    agentType: agent.agentType, enabled: enabled,
                    env: current.env ?? [:], modelProviderId: current.modelProviderId
                )
                self.surfaceAffected(affected)
                if let now = self.agents.firstIndex(where: { $0.id == agent.id }) { self.agents[now].enabled = enabled }
                return .applied
            } catch {
                if let now = self.agents.firstIndex(where: { $0.id == agent.id }) { self.agents[now].enabled = previous }
                self.refreshError = error.localizedDescription
                return .failed(error.localizedDescription)
            }
        }
        opTail = Task { @MainActor in _ = await task.value }
        let outcome = await task.value
        togglingEnabled.remove(agent.agentType)
        return outcome
    }

    private func surfaceAffected(_ n: Int) {
        if n > 0 { toast = "\(n) running session\(n == 1 ? "" : "s") will use the new config after restart." }
    }

    func clearCache(_ agent: AcpAgentInfo) async {
        guard let client else { return }
        do {
            try await client.clearBinaryCache(agentType: agent.agentType)
            toast = "Cleared \(agent.name)'s binary cache."
        } catch {
            refreshError = error.localizedDescription
        }
    }

    // MARK: - Reorder (coalescing serial sender, like Quick Messages)

    private var reorderInFlight = false
    private var pendingOrder: [AgentType]?

    func move(from source: IndexSet, to destination: Int) {
        agents.move(fromOffsets: source, toOffset: destination)
        pendingOrder = agents.map(\.agentType)
        Task { await drainReorder() }
    }

    private func drainReorder() async {
        guard !reorderInFlight, let client else { return }
        reorderInFlight = true
        defer { reorderInFlight = false }
        while let order = pendingOrder {
            pendingOrder = nil
            do { try await client.reorderAgents(order) }
            catch {
                refreshError = error.localizedDescription
                await load()
                return
            }
        }
    }
}
