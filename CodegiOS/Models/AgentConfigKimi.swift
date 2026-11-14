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
