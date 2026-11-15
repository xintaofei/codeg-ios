import Foundation

/// Settings-feature server calls, kept in an extension so `CodegClient.swift`
/// stays focused on the chat/session core. All use the same `POST /api/<name>`
/// transport (`postJSON` / `send`) as the base client. Grouped by category as the
/// feature lands batch by batch.
extension CodegClient {
    // MARK: - Quick Messages

    func quickMessagesList() async throws -> [QuickMessage] {
        try await postJSON("quick_messages_list", EmptyBody())
    }

    @discardableResult
    func quickMessageCreate(title: String, content: String) async throws -> QuickMessage {
        try await postJSON("quick_messages_create", QuickMessageCreateBody(title: title, content: content))
    }

    @discardableResult
    func quickMessageUpdate(id: Int, title: String, content: String) async throws -> QuickMessage {
        try await postJSON("quick_messages_update", QuickMessageUpdateBody(id: id, title: title, content: content))
    }

    func quickMessageDelete(id: Int) async throws {
        _ = try await send("quick_messages_delete", body: IdBody(id: id))
    }

    func quickMessagesReorder(ids: [Int]) async throws {
        _ = try await send("quick_messages_reorder", body: IdsBody(ids: ids))
    }

    // MARK: - Model Providers

    func listModelProviders() async throws -> [ModelProviderInfo] {
        try await postJSON("list_model_providers", EmptyBody())
    }

    @discardableResult
    func createModelProvider(
        name: String, apiUrl: String, apiKey: String, agentType: AgentType, model: String?
    ) async throws -> ModelProviderInfo {
        try await postJSON("create_model_provider", CreateModelProviderBody(
            name: name, apiUrl: apiUrl, apiKey: apiKey, agentType: agentType, model: model
        ))
    }

    @discardableResult
    func updateModelProvider(_ body: UpdateModelProviderBody) async throws -> UpdateModelProviderResult {
        try await postJSON("update_model_provider", body)
    }

    func deleteModelProvider(id: Int) async throws {
        _ = try await send("delete_model_provider", body: IdBody(id: id))
    }

    // MARK: - Skills (per-agent agent skills)

    func listAgentSkills(agentType: AgentType, workspacePath: String? = nil) async throws -> AgentSkillsListResult {
        try await postJSON("acp_list_agent_skills", AgentSkillsListBody(agentType: agentType, workspacePath: workspacePath))
    }

    func readAgentSkill(agentType: AgentType, scope: AgentSkillScope, skillId: String, workspacePath: String? = nil) async throws -> AgentSkillContent {
        try await postJSON("acp_read_agent_skill", AgentSkillReadBody(agentType: agentType, scope: scope, skillId: skillId, workspacePath: workspacePath))
    }

    @discardableResult
    func saveAgentSkill(agentType: AgentType, scope: AgentSkillScope, skillId: String, content: String, workspacePath: String? = nil, layout: AgentSkillLayout? = nil) async throws -> AgentSkillItem {
        try await postJSON("acp_save_agent_skill", AgentSkillSaveBody(agentType: agentType, scope: scope, skillId: skillId, content: content, workspacePath: workspacePath, layout: layout))
    }

    func deleteAgentSkill(agentType: AgentType, scope: AgentSkillScope, skillId: String, workspacePath: String? = nil) async throws {
        _ = try await send("acp_delete_agent_skill", body: AgentSkillDeleteBody(agentType: agentType, scope: scope, skillId: skillId, workspacePath: workspacePath))
    }

    // MARK: - Experts (built-in expert skills)
    // (`builtInExperts()` for `experts_list` lives in CodegClient.swift.)

    func expertInstallStatus(expertId: String) async throws -> [ExpertInstallStatus] {
        try await postJSON("experts_get_install_status", ExpertIdBody(expertId: expertId))
    }

    @discardableResult
    func expertLink(expertId: String, agentType: AgentType) async throws -> ExpertInstallStatus {
        try await postJSON("experts_link_to_agent", ExpertAgentBody(expertId: expertId, agentType: agentType))
    }

    func expertUnlink(expertId: String, agentType: AgentType) async throws {
        _ = try await send("experts_unlink_from_agent", body: ExpertAgentBody(expertId: expertId, agentType: agentType))
    }

    func expertContent(expertId: String) async throws -> String {
        try await postJSON("experts_read_content", ExpertIdBody(expertId: expertId))
    }

    // MARK: - MCP

    func mcpScanLocal() async throws -> LocalMcpScan {
        try await postJSON("mcp_scan_local", EmptyBody())
    }

    @discardableResult
    func mcpUpsertLocalServer(serverId: String, spec: JSONValue, apps: [McpAppType]) async throws -> LocalMcpServer {
        try await postJSON("mcp_upsert_local_server", McpUpsertBody(serverId: serverId, spec: spec, apps: apps))
    }

    func mcpRemoveServer(serverId: String, apps: [McpAppType]? = nil) async throws {
        _ = try await send("mcp_remove_server", body: McpRemoveBody(serverId: serverId, apps: apps))
    }

    // MARK: - General settings (feedback / ask-question)

    func feedbackEnabled() async throws -> Bool {
        let s: EnabledSetting = try await postJSON("get_feedback_settings", EmptyBody())
        return s.enabled
    }

    func setFeedbackEnabled(_ enabled: Bool) async throws {
        _ = try await send("set_feedback_settings", body: EnabledSettingsBody(settings: EnabledSetting(enabled: enabled)))
    }

    func questionEnabled() async throws -> Bool {
        let s: EnabledSetting = try await postJSON("get_question_settings", EmptyBody())
        return s.enabled
    }

    func setQuestionEnabled(_ enabled: Bool) async throws {
        _ = try await send("set_question_settings", body: EnabledSettingsBody(settings: EnabledSetting(enabled: enabled)))
    }

    /// Delegation is round-tripped as RAW JSON (no key strategy) so the snake_case
    /// scalars AND the arbitrary `agent_defaults` map (keyed by agent_type) survive
    /// load→edit→save untouched.
    func delegationSettingsRaw() async throws -> [String: Any] {
        let data = try await send("get_delegation_settings", body: EmptyBody())
        // Throw (rather than fall open to [:]) on a non-object response — a later
        // save against an empty base would silently clear `agent_defaults`.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decoding("delegation settings: expected a JSON object")
        }
        return object
    }

    func setDelegationSettingsRaw(_ settings: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["settings": settings])
        _ = try await send("set_delegation_settings", rawBody: body)
    }

    // MARK: - Agents

    func agentPreflight(agentType: AgentType, forceRefresh: Bool = false) async throws -> PreflightResult {
        try await postJSON("acp_preflight", AgentPreflightBody(agentType: agentType, forceRefresh: forceRefresh), session: Self.probeSession)
    }

    /// Replaces the agent's enabled flag, full env map, and model-provider link in
    /// one call. Returns how many running sessions still hold the old config.
    @discardableResult
    func updateAgentEnv(agentType: AgentType, enabled: Bool, env: [String: String], modelProviderId: Int?) async throws -> Int {
        try await postJSON("acp_update_agent_env", UpdateAgentEnvBody(agentType: agentType, enabled: enabled, env: env, modelProviderId: modelProviderId))
    }

    func reorderAgents(_ agentTypes: [AgentType]) async throws {
        _ = try await send("acp_reorder_agents", body: ReorderAgentsBody(agentTypes: agentTypes))
    }

    func clearBinaryCache(agentType: AgentType) async throws {
        _ = try await send("acp_clear_binary_cache", body: AgentTypeBody(agentType: agentType))
    }

    /// Writes the agent's native config files (config.json / opencode auth /
    /// codex auth + config.toml). Returns affected running sessions.
    @discardableResult
    func updateAgentConfig(_ body: UpdateAgentConfigBody) async throws -> Int {
        try await postJSON("acp_update_agent_config", body)
    }

    /// Hermes' dedicated save path (structured or raw yaml). Returns nothing.
    func updateHermesConfig(_ body: UpdateHermesConfigBody) async throws {
        _ = try await send("acp_update_hermes_config", body: body)
    }

    /// Kimi Code's dedicated save (apikey/login/raw). Returns affected running sessions.
    @discardableResult
    func updateKimiCodeConfig(_ body: UpdateKimiCodeConfigBody) async throws -> Int {
        try await postJSON("acp_update_kimi_code_config", body)
    }

    /// The model ids a provider lists, asked the way the agent's SDK would ask
    /// (`protocol`: `openai` / `anthropic` / `gemini`).
    func listProviderModels(protocol proto: String, baseUrl: String, apiKey: String) async throws -> [String] {
        let body = ListProviderModelsBody(params: .init(
            protocol: proto, baseUrl: baseUrl, keySource: .init(apiKey: apiKey)))
        let list: ProviderModelList = try await postJSON("list_provider_models", body)
        return list.models.map(\.id)
    }

    /// Probe `cursor-agent status` for the Cursor panel's auth card. `apiKey` is
    /// the key currently typed into the form (empty ⇒ test the browser login).
    /// Never throws for an unauthenticated account — that's reported in the
    /// result — only for transport failures.
    func cursorAuthStatus(apiKey: String) async throws -> CursorAuthStatus {
        try await postJSON("acp_cursor_auth_status", CursorProbeBody(apiKey: apiKey))
    }

    /// Probe `cursor-agent models` for the Cursor panel's model picker. A probe
    /// that could not run comes back as an empty list plus `error`.
    func cursorListModels(apiKey: String) async throws -> CursorModelsResult {
        try await postJSON("acp_cursor_list_models", CursorProbeBody(apiKey: apiKey))
    }

    /// pi's credentials/model save (native settings.json / auth.json). Returns nothing.
    func updatePiConfig(_ body: UpdatePiConfigBody) async throws {
        _ = try await send("acp_update_pi_config", body: body)
    }

    /// Read pi's native config projection (defaults + linked/custom providers).
    func loadPiConfig() async throws -> PiConfigProjection {
        try await postJSON("acp_load_pi_config", EmptyBody())
    }

    /// Validate a BYO-pi command/binary path. Not-found is a normal (non-throwing) result.
    func validatePiCommand(_ command: String) async throws -> PiCommandValidation {
        try await postJSON("acp_validate_pi_command", ValidatePiCommandBody(command: command), session: Self.probeSession)
    }

    /// Install / uninstall the global `pi` coding-agent binary that pi-acp spawns.
    /// Blocking (long-running → installSession); the iOS UI reconciles via `validatePiCommand`.
    func installPiBinary(taskId: String) async throws {
        _ = try await send("acp_install_pi_binary", body: TaskIdBody(taskId: taskId), session: Self.installSession)
    }

    func uninstallPiBinary(taskId: String) async throws {
        _ = try await send("acp_uninstall_pi_binary", body: TaskIdBody(taskId: taskId), session: Self.installSession)
    }

    // MARK: pi project trust

    /// Read whether pi may load this workspace's own `.pi/*`, and whether anyone
    /// here has confirmed it. Read-only probe: a failure means "don't prompt",
    /// never an error worth showing.
    func piProjectTrustState(workspace: String) async throws -> PiProjectTrustState {
        try await postJSON("acp_pi_project_trust_state", PiWorkspaceBody(workspace: workspace))
    }

    /// Record a verdict for a workspace. `true` grants, `false` declines, `nil`
    /// revokes an existing grant. The backend keeps codeg's acknowledgement in
    /// step: a grant counts as answered, while a decline or revoke clears the
    /// record so a later grant is disclosed again instead of riding on a stale
    /// "seen".
    func setPiProjectTrust(workspace: String, trusted: Bool?) async throws {
        _ = try await send("acp_pi_set_project_trust",
                           body: PiSetProjectTrustBody(workspace: workspace, trusted: trusted))
    }

    /// Keep a grant that is already in force. pi's own `trust.json` is untouched
    /// — this only records that the user has now answered for it, which is what
    /// releases the launch gate.
    func acknowledgePiProjectTrust(workspace: String) async throws {
        _ = try await send("acp_pi_acknowledge_project_trust", body: PiWorkspaceBody(workspace: workspace))
    }

    /// Every decision in pi's `trust.json`, for review and revocation.
    func listPiTrustEntries() async throws -> [PiTrustEntry] {
        try await postJSON("acp_pi_list_trust_entries", EmptyBody())
    }

    // MARK: Custom (user-registered) ACP agent definitions

    /// Fields of a listed definition that are DERIVED server-side rather than
    /// stored: `agentType` is computed from the registry id, and `launchable` /
    /// `problem` are a validation result. Everything else is echoed back on a
    /// re-save.
    ///
    /// A denylist, not a whitelist, so a writable field a newer server adds rides
    /// along instead of being silently dropped by this build. `SaveCustomAgentParams`
    /// doesn't `deny_unknown_fields`, so the three derived keys would be ignored
    /// anyway — they're excluded to keep the payload honest about what it means.
    private static let customAgentDerivedKeys: Set<String> = ["agentType", "launchable", "problem"]

    /// Stored custom-agent definitions, as RAW JSON objects.
    ///
    /// Raw — not `Decodable` — because a save is a FULL REPLACE, so a definition
    /// has to survive the read/write round-trip untouched, and nothing typed can
    /// promise that. `CustomAgentInfo` is camelCase, but its nested `spec` is the
    /// ACP registry's `distribution` object verbatim, whose fields are
    /// snake_case (`node_required`, `uv_required`, `sha256`) and which the server
    /// deserializes with NO camelCase aliases. Model that as Swift structs and
    /// the shared decoder's `.convertFromSnakeCase` turns `node_required` into
    /// `nodeRequired`, the request encoder (no key strategy) sends `nodeRequired`
    /// back, and the server drops it — the agent quietly loses its Node
    /// requirement on the next unrelated save. A spec field newer than this build
    /// would be dropped the same way, whatever the casing. `JSONSerialization`
    /// converts no keys and invents no schema, so every field the server emitted
    /// goes back under the spelling it arrived with (same approach as the
    /// delegation settings above). Not byte-for-byte — key order and formatting
    /// are not preserved, and the server round-trips `spec_json` through its own
    /// typed model anyway — but nothing is renamed or lost.
    func customAgentsRaw() async throws -> [[String: Any]] {
        let data = try await send("acp_list_custom_agents", body: EmptyBody(), session: Self.readSession)
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw APIError.decoding("custom agents: expected a JSON array of objects")
        }
        return array
    }

    /// Change ONE declaration on a stored custom-agent definition.
    ///
    /// `acp_save_custom_agent` is a full replace, so this re-reads the stored
    /// definition immediately before the write and applies `patch` to THAT — a
    /// screen holding a snapshot from when it appeared can't resurrect a value
    /// some other surface changed since. Ported from the web's
    /// `acpPatchCustomAgent`; the remaining window is read-to-write.
    func patchCustomAgent(registryId: String, patch: [String: Any]) async throws {
        let stored = try await customAgentsRaw()
        guard let current = stored.first(where: { $0["registryId"] as? String == registryId }) else {
            // Deleted elsewhere while this screen was open. Failing is right:
            // saving would re-create the definition the user just removed.
            throw APIError.transport("Custom agent “\(registryId)” no longer exists.")
        }
        // Explicit JSON nulls survive as `NSNull` and are re-sent as nulls, which
        // is what the full-replace fields (`iconUrl`, `skillsDir`, `versionProbe`)
        // need to stay cleared.
        var params = current.filter { !Self.customAgentDerivedKeys.contains($0.key) }
        params.merge(patch) { _, new in new }
        let body = try JSONSerialization.data(withJSONObject: ["params": params])
        _ = try await send("acp_save_custom_agent", rawBody: body)
    }

    // MARK: Install / version management (long-running → installSession)

    /// `binary` distribution install/upgrade. `version` nil = latest. Blocks until
    /// the download completes (or throws). `taskId` tags the server's progress
    /// stream (the iOS client reconciles via preflight + detect instead).
    func downloadAgentBinary(agentType: AgentType, taskId: String, version: String? = nil) async throws {
        _ = try await send("acp_download_agent_binary",
                           body: AgentInstallBody(agentType: agentType, taskId: taskId, version: version),
                           session: Self.installSession)
    }

    /// `npx` distribution install/upgrade. Returns the installed version string.
    @discardableResult
    func prepareNpxAgent(agentType: AgentType, registryVersion: String?, taskId: String,
                         cleanFirst: Bool, version: String? = nil) async throws -> String {
        try await postJSON("acp_prepare_npx_agent",
                           PrepareNpxBody(agentType: agentType, registryVersion: registryVersion,
                                          taskId: taskId, cleanFirst: cleanFirst, version: version),
                           session: Self.installSession)
    }

    /// Installs the `uv` runtime (prereq for `uvx` agents like Hermes).
    func installUvTool(taskId: String) async throws {
        _ = try await send("acp_install_uv_tool", body: TaskIdBody(taskId: taskId), session: Self.installSession)
    }

    func uninstallAgent(agentType: AgentType, taskId: String) async throws {
        _ = try await send("acp_uninstall_agent",
                           body: UninstallAgentBody(agentType: agentType, taskId: taskId),
                           session: Self.installSession)
    }

    /// Reads the locally-installed version (nil = not installed). Used to reconcile
    /// the UI after an install/uninstall resolves.
    func detectAgentLocalVersion(agentType: AgentType) async throws -> String? {
        try await postJSON("acp_detect_agent_local_version", AgentTypeBody(agentType: agentType), session: Self.probeSession)
    }

    // MARK: - Chat Channels

    func listChatChannels() async throws -> [ChatChannelInfo] {
        try await postJSON("list_chat_channels", EmptyBody())
    }

    func chatChannelStatus() async throws -> [ChannelStatusInfo] {
        try await postJSON("get_chat_channel_status", EmptyBody())
    }

    @discardableResult
    func createChatChannel(name: String, channelType: ChannelType, configJson: String, enabled: Bool, dailyReportEnabled: Bool, dailyReportTime: String?) async throws -> ChatChannelInfo {
        try await postJSON("create_chat_channel", CreateChatChannelBody(
            name: name, channelType: channelType, configJson: configJson,
            enabled: enabled, dailyReportEnabled: dailyReportEnabled, dailyReportTime: dailyReportTime
        ))
    }

    @discardableResult
    func updateChatChannel(_ body: UpdateChatChannelBody) async throws -> ChatChannelInfo {
        try await postJSON("update_chat_channel", body)
    }

    func deleteChatChannel(id: Int) async throws {
        _ = try await send("delete_chat_channel", body: IdBody(id: id))
    }

    func connectChatChannel(id: Int) async throws {
        _ = try await send("connect_chat_channel", body: IdBody(id: id))
    }

    func disconnectChatChannel(id: Int) async throws {
        _ = try await send("disconnect_chat_channel", body: IdBody(id: id))
    }

    func testChatChannel(id: Int) async throws {
        _ = try await send("test_chat_channel", body: IdBody(id: id))
    }

    func saveChatChannelToken(channelId: Int, token: String) async throws {
        _ = try await send("save_chat_channel_token", body: ChannelTokenBody(channelId: channelId, token: token))
    }

    func chatChannelHasToken(channelId: Int) async throws -> Bool {
        let data = try await send("get_chat_channel_has_token", body: ChannelIdOnlyBody(channelId: channelId))
        return Self.decodeBoolFragment(data)
    }

    func deleteChatChannelToken(channelId: Int) async throws {
        _ = try await send("delete_chat_channel_token", body: ChannelIdOnlyBody(channelId: channelId))
    }

    func listChatChannelMessages(channelId: Int, limit: Int? = 50, offset: Int? = nil) async throws -> [ChatChannelMessageLog] {
        try await postJSON("list_chat_channel_messages", ListChannelMessagesBody(channelId: channelId, limit: limit, offset: offset))
    }

    func weixinGetQrcode() async throws -> WeixinQrcode {
        try await postJSON("weixin_get_qrcode", EmptyBody())
    }

    /// Returns the raw status string (e.g. "pending"/"scanned"/"confirmed"/"expired").
    func weixinCheckQrcode(channelId: Int, qrcode: String) async throws -> String {
        let s: WeixinQrStatus = try await postJSON("weixin_check_qrcode", WeixinCheckBody(channelId: channelId, qrcode: qrcode))
        return s.status
    }

    // Global chat behavior settings. The GET endpoints return bare JSON fragments
    // (a string, a string[]|null) — parsed with `.fragmentsAllowed`.

    func chatCommandPrefix() async throws -> String {
        let data = try await send("get_chat_command_prefix", body: EmptyBody())
        return Self.decodeStringFragment(data) ?? "/"
    }

    func setChatCommandPrefix(_ prefix: String) async throws {
        _ = try await send("set_chat_command_prefix", body: ChatPrefixBody(prefix: prefix))
    }

    func chatMessageLanguage() async throws -> String {
        let data = try await send("get_chat_message_language", body: EmptyBody())
        return Self.decodeStringFragment(data) ?? "en"
    }

    func setChatMessageLanguage(_ language: String) async throws {
        _ = try await send("set_chat_message_language", body: ChatLanguageBody(language: language))
    }

    /// `nil` = the server's default-on set (it stored `null`).
    func chatEventFilter() async throws -> [String]? {
        let data = try await send("get_chat_event_filter", body: EmptyBody())
        if let arr = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String] {
            return arr
        }
        return nil
    }

    func setChatEventFilter(_ filter: [String]?) async throws {
        _ = try await send("set_chat_event_filter", body: ChatEventFilterBody(filter: filter))
    }

    func chatEventWebhooks() async throws -> [WebhookConfig] {
        try await postJSON("get_chat_event_webhooks", EmptyBody())
    }

    func setChatEventWebhooks(_ webhooks: [WebhookConfig]) async throws {
        _ = try await send("set_chat_event_webhooks", body: ChatWebhooksBody(webhooks: webhooks))
    }

    // MARK: - Version Control

    func detectGit() async throws -> GitDetectResult {
        try await postJSON("detect_git", EmptyBody())
    }

    func testGitPath(_ path: String) async throws -> GitDetectResult {
        try await postJSON("test_git_path", PathBody(path: path))
    }

    func gitSettings() async throws -> GitSettings {
        try await postJSON("get_git_settings", EmptyBody())
    }

    /// Wrapped `{settings:{custom_path}}` raw send (snake_case inside). A nil path
    /// is sent as explicit null to clear the override.
    func updateGitSettings(customPath: String?) async throws {
        let settings: [String: Any] = ["custom_path": customPath ?? NSNull()]
        let body = try JSONSerialization.data(withJSONObject: ["settings": settings])
        _ = try await send("update_git_settings", rawBody: body)
    }

    func githubAccounts() async throws -> [GitHubAccount] {
        let settings: GitHubAccountsSettings = try await postJSON("get_github_accounts", EmptyBody())
        return settings.accounts
    }

    /// Wrapped `{settings:{accounts:[...]}}` raw send (full replace, snake_case).
    func updateGithubAccounts(_ accounts: [GitHubAccount]) async throws {
        let settings: [String: Any] = ["accounts": accounts.map(\.snakeDict)]
        let body = try JSONSerialization.data(withJSONObject: ["settings": settings])
        _ = try await send("update_github_accounts", rawBody: body)
    }

    func validateGithubToken(serverUrl: String, token: String) async throws -> GitHubTokenValidation {
        try await postJSON("validate_github_token", ValidateGitHubTokenBody(serverUrl: serverUrl, token: token))
    }

    func saveAccountToken(accountId: String, token: String) async throws {
        _ = try await send("save_account_token", body: AccountTokenBody(accountId: accountId, token: token))
    }

    func deleteAccountToken(accountId: String) async throws {
        _ = try await send("delete_account_token", body: AccountIdBody(accountId: accountId))
    }

    // MARK: - System

    func systemProxySettings() async throws -> SystemProxySettings {
        try await postJSON("get_system_proxy_settings", EmptyBody())
    }

    func updateSystemProxySettings(enabled: Bool, proxyUrl: String?) async throws {
        let settings: [String: Any] = ["enabled": enabled, "proxy_url": proxyUrl ?? NSNull()]
        let body = try JSONSerialization.data(withJSONObject: ["settings": settings])
        _ = try await send("update_system_proxy_settings", rawBody: body)
    }

    func systemLanguageSettings() async throws -> SystemLanguageSettings {
        try await postJSON("get_system_language_settings", EmptyBody())
    }

    func updateSystemLanguageSettings(mode: String, language: String) async throws {
        let settings: [String: Any] = ["mode": mode, "language": language]
        let body = try JSONSerialization.data(withJSONObject: ["settings": settings])
        _ = try await send("update_system_language_settings", rawBody: body)
    }

    func systemTerminalSettings() async throws -> SystemTerminalSettings {
        try await postJSON("get_system_terminal_settings", EmptyBody())
    }

    func updateSystemTerminalSettings(defaultShell: String?) async throws {
        let settings: [String: Any] = ["default_shell": defaultShell ?? NSNull()]
        let body = try JSONSerialization.data(withJSONObject: ["settings": settings])
        _ = try await send("update_system_terminal_settings", rawBody: body)
    }

    func availableTerminalShells() async throws -> AvailableTerminalShells {
        try await postJSON("get_available_terminal_shells", EmptyBody())
    }

    func probeTerminalShellPath(_ path: String) async throws -> Bool {
        let data = try await send("probe_terminal_shell_path", body: PathBody(path: path))
        return Self.decodeBoolFragment(data)
    }

    func checkAppUpdate() async throws -> AppUpdateCheckResult {
        try await postJSON("check_app_update", EmptyBody())
    }
}

// Helpers for endpoints that return a bare JSON fragment (a top-level boolean or
// string) rather than an object/array — these aren't valid JSON for the typed
// decoder, so parse them with `.fragmentsAllowed` (with a string fallback).
private extension CodegClient {
    static func decodeBoolFragment(_ data: Data) -> Bool {
        if let b = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? Bool {
            return b
        }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "true"
    }

    static func decodeStringFragment(_ data: Data) -> String? {
        if let s = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String {
            return s
        }
        return nil
    }
}
