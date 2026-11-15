import Foundation

// Request bodies for the Settings feature's server calls. camelCase property
// names go on the wire verbatim (the shared encoder applies no key strategy), so
// they match the web's `getTransport().call(name, {camelCaseKeys})` params.
// Optionals are omitted when nil — which the server's serde `Option<T>` reads as
// `None`, identical to the web sending an explicit `null`.

// MARK: - Shared

/// `{ id }` — delete-by-id (quick_messages_delete, delete_model_provider, …).
struct IdBody: Encodable, Sendable {
    let id: Int
}

/// `{ ids }` — reorder by id list (quick_messages_reorder, …).
struct IdsBody: Encodable, Sendable {
    let ids: [Int]
}

// MARK: - Quick Messages

struct QuickMessageCreateBody: Encodable, Sendable {
    let title: String
    let content: String
}

struct QuickMessageUpdateBody: Encodable, Sendable {
    let id: Int
    let title: String
    let content: String
}

// MARK: - Model Providers

struct CreateModelProviderBody: Encodable, Sendable {
    let name: String
    let apiUrl: String
    let apiKey: String
    let agentType: AgentType
    var model: String?
}

/// Update — every field but `id` is optional; an omitted field means "keep" on
/// the server. `apiKey` is sent only when the user re-enters one. `model` carries
/// an empty string to explicitly clear, nil to keep.
struct UpdateModelProviderBody: Encodable, Sendable {
    let id: Int
    var name: String?
    var apiUrl: String?
    var apiKey: String?
    var agentType: AgentType?
    var model: String?
}

// MARK: - Skills (per-agent agent skills)

struct AgentSkillsListBody: Encodable, Sendable {
    let agentType: AgentType
    var workspacePath: String?
}

struct AgentSkillReadBody: Encodable, Sendable {
    let agentType: AgentType
    let scope: AgentSkillScope
    let skillId: String
    var workspacePath: String?
}

struct AgentSkillSaveBody: Encodable, Sendable {
    let agentType: AgentType
    let scope: AgentSkillScope
    let skillId: String
    let content: String
    var workspacePath: String?
    var layout: AgentSkillLayout?
}

struct AgentSkillDeleteBody: Encodable, Sendable {
    let agentType: AgentType
    let scope: AgentSkillScope
    let skillId: String
    var workspacePath: String?
}

// MARK: - Experts

struct ExpertIdBody: Encodable, Sendable {
    let expertId: String
}

struct ExpertAgentBody: Encodable, Sendable {
    let expertId: String
    let agentType: AgentType
}

// MARK: - MCP

struct McpUpsertBody: Encodable, Sendable {
    let serverId: String
    let spec: JSONValue
    let apps: [McpAppType]
}

struct McpRemoveBody: Encodable, Sendable {
    let serverId: String
    var apps: [McpAppType]?
}

// MARK: - General (feedback / ask-question)

/// `{enabled}` — shared by feedback + ask-question settings (both the GET
/// response and the SET body's inner object). "enabled" is identical in
/// snake/camel, so a plain Codable round-trips correctly.
struct EnabledSetting: Codable, Sendable {
    var enabled: Bool
}

struct EnabledSettingsBody: Encodable, Sendable {
    let settings: EnabledSetting
}

// MARK: - Agents

struct AgentPreflightBody: Encodable, Sendable {
    let agentType: AgentType
    var forceRefresh: Bool?
}

struct UpdateAgentEnvBody: Encodable, Sendable {
    let agentType: AgentType
    let enabled: Bool
    let env: [String: String]
    var modelProviderId: Int?
}

struct ReorderAgentsBody: Encodable, Sendable {
    let agentTypes: [AgentType]
}

/// Grok's structured controls sent inside `acp_update_agent_config` — each
/// non-null value sets its `~/.grok/config.toml` key, each null removes it (so a
/// cleared dropdown actually deletes the key). camelCase on the wire, explicit
/// nulls, mirroring the web `GrokStructuredConfig` / `buildGrokStructuredConfig`.
struct GrokStructuredConfig: Encodable, Sendable {
    var permissionMode: String?
    var defaultReasoningEffort: String?

    enum CodingKeys: String, CodingKey { case permissionMode, defaultReasoningEffort }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let permissionMode { try c.encode(permissionMode, forKey: .permissionMode) }
        else { try c.encodeNil(forKey: .permissionMode) }
        if let defaultReasoningEffort { try c.encode(defaultReasoningEffort, forKey: .defaultReasoningEffort) }
        else { try c.encodeNil(forKey: .defaultReasoningEffort) }
    }
}

/// Cursor's structured controls sent inside `acp_update_agent_config`, merged
/// onto the current on-disk `~/.cursor/cli-config.json` so keys written by the
/// CLI's own `/config` UI survive.
///
/// Unlike ``GrokStructuredConfig``, an absent field here means "leave that key
/// alone" (the backend's `Option` is a patch, not a set-or-delete), so this omits
/// nil fields instead of sending explicit nulls. The rule lists are replaced
/// wholesale, so an emptied list is sent as `[]` — that's a real "no rules", not
/// an omission.
struct CursorStructuredConfig: Encodable, Sendable {
    var sandboxMode: String?
    var permissionsAllow: [String]?
    var permissionsDeny: [String]?
}

/// `acp_update_agent_config` — writes the native config files. Every payload key
/// is always sent (explicit `null` when not applicable for the agent type),
/// matching the web which never omits them. `grokConfigToml`/`grokStructured`
/// and `cursorCliConfigJson`/`cursorStructured` are the two merge-style
/// surfaces: the raw file text (only when the user edited it) plus the
/// structured controls the backend merges onto it.
struct UpdateAgentConfigBody: Encodable, Sendable {
    let agentType: AgentType
    var configJson: String?
    var opencodeAuthJson: String?
    var codexAuthJson: String?
    var codexConfigToml: String?
    var grokConfigToml: String?
    var grokStructured: GrokStructuredConfig?
    var cursorCliConfigJson: String?
    var cursorStructured: CursorStructuredConfig?

    enum CodingKeys: String, CodingKey {
        case agentType, configJson, opencodeAuthJson, codexAuthJson, codexConfigToml
        case grokConfigToml, grokStructured, cursorCliConfigJson, cursorStructured
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentType, forKey: .agentType)
        try c.encodeNilable(configJson, forKey: .configJson)
        try c.encodeNilable(opencodeAuthJson, forKey: .opencodeAuthJson)
        try c.encodeNilable(codexAuthJson, forKey: .codexAuthJson)
        try c.encodeNilable(codexConfigToml, forKey: .codexConfigToml)
        try c.encodeNilable(grokConfigToml, forKey: .grokConfigToml)
        if let grokStructured { try c.encode(grokStructured, forKey: .grokStructured) }
        else { try c.encodeNil(forKey: .grokStructured) }
        try c.encodeNilable(cursorCliConfigJson, forKey: .cursorCliConfigJson)
        if let cursorStructured { try c.encode(cursorStructured, forKey: .cursorStructured) }
        else { try c.encodeNil(forKey: .cursorStructured) }
    }
}

/// `acp_cursor_auth_status` / `acp_cursor_list_models` — the probe key is the one
/// typed into the panel (so the probes test what's on screen, not what's saved);
/// empty/nil means "use the browser-login credential".
struct CursorProbeBody: Encodable, Sendable {
    var apiKey: String?
}

/// `acp_update_hermes_config` — hermes' separate save path. `apiKey`/`baseUrl`
/// are `null = keep stored value` (A2), `rawConfigYaml` only sent in raw mode.
/// Optional fields are OMITTED when nil (the structured save passes explicit
/// `.some(nil)`-style via the call site — see `updateHermesConfig`).
struct UpdateHermesConfigBody: Encodable, Sendable {
    let provider: String
    var model: String?
    /// `.keep` omits the key; `.clear` sends explicit null; `.set` sends the value.
    var apiKey: FieldEdit<String> = .keep
    var baseUrl: FieldEdit<String> = .keep
    var rawConfigYaml: String?

    enum CodingKeys: String, CodingKey { case provider, model, apiKey, baseUrl, rawConfigYaml }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        switch apiKey {
        case .keep: break
        case .clear: try c.encodeNil(forKey: .apiKey)
        case .set(let v): try c.encode(v, forKey: .apiKey)
        }
        switch baseUrl {
        case .keep: break
        case .clear: try c.encodeNil(forKey: .baseUrl)
        case .set(let v): try c.encode(v, forKey: .baseUrl)
        }
        try c.encodeIfPresent(rawConfigYaml, forKey: .rawConfigYaml)
    }
}

/// `acp_update_kimi_code_config` — discriminated on `mode` (`apikey`|`login`|`raw`).
/// camelCase wire (matches the backend `rename_all="camelCase"`); nil optionals are
/// omitted, which the backend's `#[serde(default)]` reads as absent (same as null).
///
/// The four reasoning fields are NOT "leave alone when absent": an `apikey` save
/// rebuilds the whole managed model block from this body, so every one must
/// carry the reasoning card's edit or echo what is on disk — see `kimiBodyForSave`.
struct UpdateKimiCodeConfigBody: Encodable, Sendable {
    let mode: String
    var interfaceType: String?
    var authType: String?
    var baseUrl: String?
    var apiKey: String?
    var model: String?
    var maxContextSize: Int?
    var vertexProject: String?
    var vertexLocation: String?
    var rawConfigToml: String?
    /// Declares a thinking capability: what makes `kimi acp` offer its Thinking picker.
    var reasoningEnabled: Bool?
    /// `always_thinking` instead of `thinking`: the picker has no Off row.
    var alwaysThinking: Bool?
    /// The reasoning levels the composer offers.
    var supportEfforts: [String]?
    /// The level the picker opens on; the backend drops one outside `supportEfforts`.
    var defaultEffort: String?
}

/// `list_provider_models` (codeg 0.37+, replacing the per-agent
/// `acp_fetch_kimi_models`): list a provider's models over its own protocol,
/// which doubles as a key test. Wrapped in `params` on the wire.
struct ListProviderModelsBody: Encodable, Sendable {
    struct Params: Encodable, Sendable {
        /// Rust `ModelsProtocol`: `openai` / `anthropic` / `gemini`.
        let `protocol`: String
        let baseUrl: String
        let keySource: KeySource
    }
    /// Rust `ModelsKeySource`, internally tagged by `kind`. Only the inline key
    /// this client's settings forms hold is modelled.
    struct KeySource: Encodable, Sendable {
        let kind = "inline"
        let apiKey: String
    }
    let params: Params
}

/// Rust `ModelList`: the URL that answered, and the models in the provider's
/// order. camelCase on the wire, which the snake-case decoder leaves intact.
struct ProviderModelList: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let id: String
        let displayName: String?
    }
    let url: String?
    let models: [Model]
}

/// `acp_update_pi_config` — writes pi's native settings.json/auth.json. camelCase
/// wire; nil optionals omitted (backend `#[serde(default)]`).
struct UpdatePiConfigBody: Encodable, Sendable {
    let provider: String
    let model: String
    var thinkingLevel: String?
    var apiKey: String?
    var customBaseUrl: String?
    var customApi: String?
}

/// `acp_validate_pi_command` — check a BYO-pi binary path/command.
struct ValidatePiCommandBody: Encodable, Sendable {
    let command: String
}

/// `acp_pi_project_trust_state` / `acp_pi_acknowledge_project_trust`.
struct PiWorkspaceBody: Encodable, Sendable {
    let workspace: String
}

/// `acp_pi_set_project_trust`. `trusted` is three-valued: `true` grants,
/// `false` declines, and an explicit `null` REVOKES codeg's entry for this exact
/// folder rather than recording a verdict — so it is encoded even when nil,
/// never omitted.
struct PiSetProjectTrustBody: Encodable, Sendable {
    let workspace: String
    let trusted: Bool?

    enum CodingKeys: String, CodingKey { case workspace, trusted }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(trusted, forKey: .trusted)
    }
}

/// `acp_download_agent_binary` / shared install shape. `version` is sent as
/// explicit `null` for "latest" (web parity).
struct AgentInstallBody: Encodable, Sendable {
    let agentType: AgentType
    let taskId: String
    var version: String?

    enum CodingKeys: String, CodingKey { case agentType, taskId, version }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentType, forKey: .agentType)
        try c.encode(taskId, forKey: .taskId)
        try c.encodeNilable(version, forKey: .version)
    }
}

/// `acp_prepare_npx_agent`.
struct PrepareNpxBody: Encodable, Sendable {
    let agentType: AgentType
    var registryVersion: String?
    let taskId: String
    let cleanFirst: Bool
    var version: String?

    enum CodingKeys: String, CodingKey { case agentType, registryVersion, taskId, cleanFirst, version }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentType, forKey: .agentType)
        try c.encodeNilable(registryVersion, forKey: .registryVersion)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(cleanFirst, forKey: .cleanFirst)
        try c.encodeNilable(version, forKey: .version)
    }
}

/// `acp_install_uv_tool` / `acp_uninstall_agent` (the latter also carries agentType).
struct TaskIdBody: Encodable, Sendable { let taskId: String }

struct UninstallAgentBody: Encodable, Sendable {
    let agentType: AgentType
    let taskId: String
}

private extension KeyedEncodingContainer {
    /// Encode an optional String emitting an explicit JSON `null` when nil
    /// (vs `encodeIfPresent` which omits the key).
    mutating func encodeNilable(_ value: String?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

// MARK: - Chat Channels
//
// Key-name split (verified against api.ts): CRUD + connect/disconnect/test use
// `{id}` (→ reuse `IdBody`); token + message-log + weixin-check use `{channelId}`.

struct CreateChatChannelBody: Encodable, Sendable {
    let name: String
    let channelType: ChannelType
    let configJson: String
    let enabled: Bool
    let dailyReportEnabled: Bool
    var dailyReportTime: String?
}

/// Tri-state edit for `update_chat_channel`'s double-`Option` fields: `.keep`
/// omits the key (server keeps the stored value), `.clear` sends an explicit
/// `null` (server clears it), `.set(v)` sends the value.
enum FieldEdit<Value: Encodable & Sendable>: Sendable {
    case keep
    case clear
    case set(Value)
}

/// Partial update. `name`/`enabled`/`configJson`/`dailyReportEnabled` are simple
/// "omit = keep" optionals. `dailyReportTime` is a tri-state so it can be
/// explicitly cleared when the report is turned off (the server field is
/// `Option<Option<String>>`, distinguishing omit=keep from null=clear). There is
/// no `channelType` (immutable after create) and no `eventFilterJson` (per-channel
/// event overrides aren't edited here — the global event filter is its own
/// endpoint, so the field is left untouched = kept).
struct UpdateChatChannelBody: Encodable, Sendable {
    let id: Int
    var name: String?
    var enabled: Bool?
    var configJson: String?
    var dailyReportEnabled: Bool?
    var dailyReportTime: FieldEdit<String> = .keep

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, configJson, dailyReportEnabled, dailyReportTime
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(configJson, forKey: .configJson)
        try c.encodeIfPresent(dailyReportEnabled, forKey: .dailyReportEnabled)
        switch dailyReportTime {
        case .keep: break
        case .clear: try c.encodeNil(forKey: .dailyReportTime)
        case .set(let value): try c.encode(value, forKey: .dailyReportTime)
        }
    }
}

/// `{channelId, token}` — save the keyring secret for a channel.
struct ChannelTokenBody: Encodable, Sendable {
    let channelId: Int
    let token: String
}

/// `{channelId}` — has-token / delete-token / (base for message list).
struct ChannelIdOnlyBody: Encodable, Sendable {
    let channelId: Int
}

struct ListChannelMessagesBody: Encodable, Sendable {
    let channelId: Int
    var limit: Int?
    var offset: Int?
}

struct WeixinCheckBody: Encodable, Sendable {
    let channelId: Int
    let qrcode: String
}

// Global chat behavior settings (stored in app_metadata, not per-channel).
struct ChatPrefixBody: Encodable, Sendable { let prefix: String }
struct ChatLanguageBody: Encodable, Sendable { let language: String }

/// `{filter}` — an explicit JSON `null` means "reset to the server default set".
/// A custom encoder is required because synthesized `Encodable` would omit the
/// key when `filter == nil` (`encodeIfPresent`) rather than send `null`; this
/// matches the web client, which always sends the key.
struct ChatEventFilterBody: Encodable, Sendable {
    let filter: [String]?

    enum CodingKeys: String, CodingKey { case filter }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let filter { try c.encode(filter, forKey: .filter) }
        else { try c.encodeNil(forKey: .filter) }
    }
}

struct ChatWebhooksBody: Encodable, Sendable { let webhooks: [WebhookConfig] }

// MARK: - Version Control + System
//
// The `update_*_settings` methods are wrapped `{settings:{snake_case...}}` and
// sent as raw JSON (like delegation), so only the flat methods need typed bodies.
// (test_git_path / probe_terminal_shell_path reuse the existing `PathBody`.)

struct ValidateGitHubTokenBody: Encodable, Sendable {
    let serverUrl: String
    let token: String
}

/// `{accountId, token}` — save the account's keyring token.
struct AccountTokenBody: Encodable, Sendable {
    let accountId: String
    let token: String
}

/// `{accountId}` — delete the account's keyring token.
struct AccountIdBody: Encodable, Sendable {
    let accountId: String
}
