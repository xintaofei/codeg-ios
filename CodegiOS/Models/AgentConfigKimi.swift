import Foundation

// Kimi Code (Moonshot AI) config model — ported from the web
// `acp-agent-settings.tsx` Kimi helpers. `kimi acp` gates every session on a
// stored token and rejects a bare API key, so codeg manages BOTH a
// `~/.kimi-code/config.toml` provider block AND a synthetic gate token; the panel
// keeps exactly one source authoritative (apikey / login / raw), enforced by the
// `acp_update_kimi_code_config` backend. The current state is projected into
// `AcpAgentInfo.configJson` as a camelCase JSON string (`KimiManagedConfig`).

/// Which credential source is authoritative. `apikey` writes the managed
/// config.toml block + seeds the gate token; `login` clears both so a real
/// `kimi login` OAuth session governs.
enum KimiAuthMode: String, CaseIterable, Sendable, Hashable {
    case apikey
    case login
}

/// The six provider `type` values Kimi's config.toml `[providers]` accepts (raw
/// values match the on-disk `type`).
enum KimiInterfaceType: String, CaseIterable, Sendable, Hashable {
    case kimi
    case openai
    case openaiResponses = "openai_responses"
    case anthropic
    case googleGenai = "google-genai"
    case vertexai
}

/// Native-provider credential placement: inline `api_key` vs the env sub-table.
enum KimiNativeAuthType: String, CaseIterable, Sendable, Hashable {
    case apiKey = "api_key"
    case env
}

/// Env-mode endpoint: the two Moonshot regions or a custom OpenAI-compatible URL.
enum KimiEndpointRegion: String, CaseIterable, Sendable, Hashable {
    case international
    case china
    case custom
}

let kimiBaseUrlInternational = "https://api.moonshot.ai/v1"
let kimiBaseUrlChina = "https://api.moonshot.cn/v1"
/// Placeholder model id (a real Moonshot coding model) for the model input.
let kimiModelPlaceholder = "kimi-k2.7-code"

struct KimiInterfaceTypeMeta: Sendable {
    let value: KimiInterfaceType
    /// Product label (proper noun — intentionally not localized).
    let label: String
    /// Base URL pre-filled when this interface is selected ("" → SDK default).
    let defaultBaseUrl: String
    /// vertexai authenticates via GCP ADC, so it exposes no API key field.
    let usesApiKey: Bool

    /// The protocol this interface's SDK lists models over
    /// (`list_provider_models`), or nil when there is no key to list with.
    /// Mirrors the web's `modelsProtocol`.
    var modelsProtocol: String? {
        switch value {
        case .kimi, .openai, .openaiResponses: return "openai"
        case .anthropic: return "anthropic"
        case .googleGenai: return "gemini"
        case .vertexai: return nil
        }
    }

    /// Where the SDK goes when the base URL is left blank — so the listing asks
    /// the same endpoint the agent will. Mirrors the web's `sdkBaseUrl`.
    var sdkBaseUrl: String {
        switch value {
        case .kimi: return kimiBaseUrlInternational
        case .anthropic: return "https://api.anthropic.com"
        case .googleGenai: return "https://generativelanguage.googleapis.com"
        case .openai, .openaiResponses, .vertexai: return ""
        }
    }
}

let kimiInterfaceTypes: [KimiInterfaceTypeMeta] = [
    .init(value: .kimi, label: "Kimi / Moonshot", defaultBaseUrl: kimiBaseUrlInternational, usesApiKey: true),
    .init(value: .openai, label: "OpenAI (Chat Completions)", defaultBaseUrl: "https://api.openai.com/v1", usesApiKey: true),
    .init(value: .openaiResponses, label: "OpenAI (Responses)", defaultBaseUrl: "https://api.openai.com/v1", usesApiKey: true),
    .init(value: .anthropic, label: "Anthropic", defaultBaseUrl: "", usesApiKey: true),
    .init(value: .googleGenai, label: "Google Gemini", defaultBaseUrl: "", usesApiKey: true),
    .init(value: .vertexai, label: "Google Vertex AI", defaultBaseUrl: "", usesApiKey: false),
]

func kimiInterfaceMeta(_ type: KimiInterfaceType) -> KimiInterfaceTypeMeta {
    kimiInterfaceTypes.first { $0.value == type } ?? kimiInterfaceTypes[0]
}

/// Region implied by an env-mode base URL: `.cn` → china, `.ai` or empty →
/// international, any other non-empty endpoint → custom.
func kimiEndpointRegionFromBaseUrl(_ baseUrl: String) -> KimiEndpointRegion {
    let raw = baseUrl.trimmingCharacters(in: .whitespaces).lowercased()
    if raw.isEmpty { return .international }
    if raw.contains("moonshot.cn") { return .china }
    if raw.contains("moonshot.ai") { return .international }
    return .custom
}

func kimiBaseUrlForRegion(_ region: KimiEndpointRegion, _ customUrl: String) -> String {
    switch region {
    case .china: return kimiBaseUrlChina
    case .custom: return customUrl.trimmingCharacters(in: .whitespaces)
    case .international: return kimiBaseUrlInternational
    }
}

/// The context window the backend writes when a save sends none: Kimi's schema
/// requires `max_context_size` on the managed model block, so it is never
/// omitted. Pre-filled into the field so the form shows what lands on disk.
let kimiDefaultMaxContextSize = 262_144

/// `capabilities` entries that make `kimi acp` advertise its Thinking picker
/// (backend `KIMI_CAPABILITY_THINKING` / `KIMI_CAPABILITY_ALWAYS_THINKING`).
let kimiCapabilityThinking = "thinking"
let kimiCapabilityAlwaysThinking = "always_thinking"

/// Reasoning levels offered as one-click chips (web `KIMI_COMMON_EFFORTS`).
/// NOT an enum codeg enforces — kimi forwards the string to the provider
/// unmapped, so the right set depends on the model. Anything else goes in
/// through the custom-level field.
let kimiCommonEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

/// The reasoning card's four values (the reasoning slice of the web
/// `KimiDraft`). Equality is by value, so a freshly seeded card never reads as
/// edited and an added, removed or reordered level does.
struct KimiReasoningDraft: Equatable, Sendable {
    /// Declares a thinking capability — the gate on kimi offering the
    /// composer's Thinking picker at all.
    var reasoningEnabled = false
    /// `always_thinking` rather than `thinking`: the picker loses its Off row.
    var alwaysThinking = false
    /// The levels the picker offers. Empty → kimi degrades it to Off / On.
    var supportEfforts: [String] = []
    /// The level the picker opens on; "" lets kimi choose.
    var defaultEffort = ""

    init(reasoningEnabled: Bool = false, alwaysThinking: Bool = false,
         supportEfforts: [String] = [], defaultEffort: String = "") {
        self.reasoningEnabled = reasoningEnabled
        self.alwaysThinking = alwaysThinking
        self.supportEfforts = supportEfforts
        self.defaultEffort = defaultEffort
    }

    /// Seeded from the backend projection (web `kimiDraftFromConfig`): either
    /// thinking capability reads as on, exactly like kimi's `supportsThinking`.
    init(_ config: KimiManagedConfig) {
        self.init(reasoningEnabled: config.reasoningEnabled,
                  alwaysThinking: config.alwaysThinking,
                  supportEfforts: config.supportEfforts,
                  defaultEffort: config.defaultEffort ?? "")
    }

    /// The chips: the common levels, then any offered level outside them (a
    /// hand-written one from config.toml stays togglable instead of vanishing).
    var effortChoices: [String] {
        var seen = Set<String>()
        return (kimiCommonEfforts + supportEfforts).filter { seen.insert($0).inserted }
    }

    /// Flip one chip. Switching a level on keeps chip order rather than click
    /// order, so the written list reads low→high like kimi's own profiles; a
    /// default whose level just went is dropped (kimi would clamp it anyway).
    mutating func toggleEffort(_ effort: String) {
        if supportEfforts.contains(effort) {
            supportEfforts.removeAll { $0 == effort }
        } else {
            let current = supportEfforts
            supportEfforts = effortChoices.filter { $0 == effort || current.contains($0) }
        }
        if !supportEfforts.contains(defaultEffort) { defaultEffort = "" }
    }

    /// Offer a typed level: trimmed, appended, ignored when blank or already offered.
    mutating func addCustomEffort(_ raw: String) {
        let effort = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effort.isEmpty, !supportEfforts.contains(effort) else { return }
        supportEfforts.append(effort)
    }

    /// The web's `errorDefaultEffortUnlisted`, which blocks an API-key save:
    /// kimi silently clamps a default outside the offered levels to the middle
    /// entry, so the composer would open on a level nobody chose. Not checked
    /// while reasoning is off or no level is offered.
    var defaultEffortIsUnlisted: Bool {
        let effort = defaultEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return reasoningEnabled && !effort.isEmpty && !supportEfforts.isEmpty
            && !supportEfforts.contains(effort)
    }
}

/// The reasoning card at save time: what it holds and what it was last seeded
/// with from disk. A field that still equals its seed counts as untouched.
struct KimiReasoningEdit: Equatable, Sendable {
    var draft: KimiReasoningDraft
    var baseline: KimiReasoningDraft

    /// Field by field: the card's value where the user changed it, `onDisk`'s
    /// where they didn't — so a change made elsewhere since the card was seeded
    /// survives unless the user overrode that same field here.
    ///
    /// Throws `KimiReasoningConflict` when that pairs a default and a level
    /// list from different sources that no longer agree (a default picked here
    /// whose level was removed elsewhere, or a level removed here that is now
    /// the default elsewhere): the backend would silently drop the default.
    /// Only a change made elsewhere can cause it — a pair wholly from the card
    /// passed its validation, and one wholly from disk is what's there already.
    func resolved(onDisk: KimiReasoningDraft) throws -> KimiReasoningDraft {
        var out = onDisk
        let effortsEdited = draft.supportEfforts != baseline.supportEfforts
        let defaultEdited = draft.defaultEffort != baseline.defaultEffort
        if draft.reasoningEnabled != baseline.reasoningEnabled { out.reasoningEnabled = draft.reasoningEnabled }
        if draft.alwaysThinking != baseline.alwaysThinking { out.alwaysThinking = draft.alwaysThinking }
        if effortsEdited { out.supportEfforts = draft.supportEfforts }
        if defaultEdited { out.defaultEffort = draft.defaultEffort }
        if out.reasoningEnabled && effortsEdited != defaultEdited {
            let effort = out.defaultEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            if !effort.isEmpty && !out.supportEfforts.contains(effort) { throw KimiReasoningConflict() }
        }
        return out
    }
}

/// The reasoning card's edit can't be combined with what changed on disk
/// meanwhile, so nothing is written (see `KimiReasoningEdit.resolved`).
struct KimiReasoningConflict: LocalizedError, Equatable {
    var errorDescription: String? {
        "Kimi’s reasoning settings were changed elsewhere while you edited them, so nothing was saved. They’ve been reloaded — check them and save again."
    }
}

/// The Kimi save body to actually send. An `apikey` save makes the backend
/// REBUILD the managed model block, reading an absent `reasoningEnabled` as
/// off and dropping `capabilities` / `support_efforts` / `default_effort` — so
/// all four always go out. Each is the reasoning card's value where the user
/// edited it, else the declaration already on disk, read from
/// `freshConfigJson` (the live `acp_list_agents` projection re-read at save
/// time, not the copy the panel opened with, so a change made elsewhere
/// meanwhile isn't reverted). `reasoning == nil` carries all four. Reasoning
/// off sends no levels and no default, like the web, so the backend omits
/// `capabilities` and kimi keeps its permissive default. Throws
/// `KimiReasoningConflict` rather than build a body the backend would quietly
/// change. `login` clears the block and `raw` writes verbatim TOML, so both
/// pass through untouched.
func kimiBodyForSave(_ body: UpdateKimiCodeConfigBody, reasoning: KimiReasoningEdit? = nil,
                     freshConfigJson: String?) throws -> UpdateKimiCodeConfigBody {
    guard body.mode == "apikey" else { return body }
    let onDisk = KimiReasoningDraft(KimiManagedConfig.parse(freshConfigJson))
    let r = try reasoning?.resolved(onDisk: onDisk) ?? onDisk
    var out = body
    out.reasoningEnabled = r.reasoningEnabled
    out.alwaysThinking = r.reasoningEnabled && r.alwaysThinking
    out.supportEfforts = r.reasoningEnabled ? r.supportEfforts : []
    out.defaultEffort = r.reasoningEnabled ? r.defaultEffort : nil
    return out
}

/// Mirror of the backend `load_kimi_code_config_json` projection (camelCase keys),
/// parsed from `AcpAgentInfo.configJson`. Deliberately NOT `apiKey`/`model`/`env`
/// so the projected block never leaks back into the runtime env.
struct KimiManagedConfig: Sendable {
    var interfaceType: KimiInterfaceType?
    var baseUrl: String?
    var key: String?
    var authType: KimiNativeAuthType?
    var modelId: String?
    var maxContextSize: Int?
    var vertexProject: String?
    var vertexLocation: String?
    var hasManagedBlock: Bool?
    /// Whether `kimi acp`'s session gate is satisfied (a token file is present).
    var credentialPresent: Bool?
    /// Whether that gate token is codeg's synthetic one (vs a real OAuth login).
    var credentialSynthetic: Bool?
    var rawConfigToml: String?
    /// `[models.<alias>].capabilities` as written on disk. A `thinking` /
    /// `always_thinking` entry is what makes `kimi acp` offer its Thinking
    /// picker at all.
    var capabilities: [String] = []
    /// `support_efforts`: the reasoning levels the composer offers.
    var supportEfforts: [String] = []
    /// `default_effort`: the level the picker opens on.
    var defaultEffort: String?

    /// Kimi's own `supportsThinking`: either capability turns the picker on.
    var reasoningEnabled: Bool {
        capabilities.contains(kimiCapabilityThinking) || capabilities.contains(kimiCapabilityAlwaysThinking)
    }
    /// The always-on flavour: the picker has no Off row.
    var alwaysThinking: Bool { capabilities.contains(kimiCapabilityAlwaysThinking) }

    /// Parse the config_json string. Missing/unparseable → an empty config (the
    /// panel treats that as "not configured yet"). Unknown enum values fall back to
    /// nil rather than failing the whole parse.
    static func parse(_ configJson: String?) -> KimiManagedConfig {
        guard let s = configJson?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KimiManagedConfig() }
        var c = KimiManagedConfig()
        c.interfaceType = (obj["interfaceType"] as? String).flatMap(KimiInterfaceType.init(rawValue:))
        c.baseUrl = obj["baseUrl"] as? String
        c.key = obj["key"] as? String
        c.authType = (obj["authType"] as? String).flatMap(KimiNativeAuthType.init(rawValue:))
        c.modelId = obj["modelId"] as? String
        c.maxContextSize = (obj["maxContextSize"] as? NSNumber)?.intValue
        c.vertexProject = obj["vertexProject"] as? String
        c.vertexLocation = obj["vertexLocation"] as? String
        c.hasManagedBlock = obj["hasManagedBlock"] as? Bool
        c.credentialPresent = obj["credentialPresent"] as? Bool
        c.credentialSynthetic = obj["credentialSynthetic"] as? Bool
        c.rawConfigToml = obj["rawConfigToml"] as? String
        func strings(_ key: String) -> [String] {
            ((obj[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        c.capabilities = strings("capabilities")
        c.supportEfforts = strings("supportEfforts")
        if let effort = (obj["defaultEffort"] as? String)?.trimmingCharacters(in: .whitespaces), !effort.isEmpty {
            c.defaultEffort = effort
        }
        return c
    }
}

/// Initial panel mode: the codeg-managed API-key block wins; otherwise a real
/// (non-synthetic) OAuth login shows login; else default to the API-key form.
func kimiInitialMode(_ config: KimiManagedConfig) -> KimiAuthMode {
    if config.hasManagedBlock == true { return .apikey }
    if config.credentialPresent == true && config.credentialSynthetic != true { return .login }
    return .apikey
}
