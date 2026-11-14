import Foundation

// Pi (self-extensible coding agent) config model — ported from the web
// `PiConfigPanel`. pi has three concerns, each with its own store:
//  • Credentials/model → pi's native ~/.pi/agent/{settings,auth,models}.json via
//    `acp_update_pi_config` / `acp_load_pi_config`.
//  • Runtime (bring-your-own-pi) → a default↔custom toggle writing PI_ACP_PI_COMMAND
//    (+ optional dir overrides) into the per-agent env.
//  • Project trust → per-workspace decisions in pi's own ~/.pi/agent/trust.json,
//    read and written through the `acp_pi_*_project_trust` endpoints.

/// Response of `acp_load_pi_config` (camelCase wire; the shared `.convertFromSnakeCase`
/// decoder leaves underscore-free keys untouched, so natural props decode directly).
struct PiConfigProjection: Decodable, Sendable {
    var defaultProvider: String?
    var defaultModel: String?
    var defaultThinkingLevel: String?
    var authProviders: [String]
    var customProviders: [PiCustomProvider]
}

struct PiCustomProvider: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let baseUrl: String
    let api: String
}

/// Response of `acp_validate_pi_command`. Not-found is a normal result (found=false).
struct PiCommandValidation: Decodable, Sendable, Equatable {
    let found: Bool
    let resolvedPath: String?
    let version: String?
}

/// Which pi binary pi-acp spawns.
enum PiRuntimeMode: String, CaseIterable, Sendable, Hashable {
    case `default`
    case custom
}

enum PiEnvKeys {
    static let command = "PI_ACP_PI_COMMAND"
    static let configDir = "PI_CODING_AGENT_DIR"
    static let sessionDir = "PI_CODING_AGENT_SESSION_DIR"
}

// MARK: - Project trust

/// Response of `acp_pi_project_trust_state` — whether pi may load a repo's own
/// `.pi/*` in this workspace, and whether anyone here has said so.
///
/// pi resolves trust once, at process startup, and `.pi/extensions` are JS/TS
/// modules whose top level runs immediately with the user's permissions. Because
/// pi-acp spawns `pi --mode rpc` (no UI) pi cannot ask, so its own default is to
/// skip those resources — and codeg used to answer "yes" on the user's behalf by
/// seeding the grant on every launch. That is gone, which leaves two cases for
/// the UI: nothing has decided (resources stay unloaded), or a grant is in force
/// that nobody here confirmed — and the backend refuses to launch pi at all while
/// such a grant stands.
struct PiProjectTrustState: Decodable, Sendable, Equatable {
    /// Canonical directory the decision is (or would be) keyed by. Can differ
    /// from the path asked about (`/tmp` vs `/private/tmp`) — always write the
    /// decision back with THIS, never the requested path.
    let workspace: String
    /// Repo-shipped resources gated by the decision. Empty ⇒ nothing to approve.
    let resources: [PiProjectResource]
    /// The verdict in force, or nil when no ancestor has decided yet.
    let decision: Bool?
    /// Which directory carries the deciding entry — may be an ancestor, which is
    /// how a repo cloned into a long-ago-trusted folder is trusted before it is
    /// ever opened.
    let decidedAt: String?
    /// Absolute path of pi's `trust.json`, so the UI can name the real file.
    let trustFile: String
    /// Whether the user has been shown, in this codeg, that this folder is
    /// trusted. A grant with `acknowledged == false` is one nobody here has
    /// confirmed and it BLOCKS the launch until answered.
    let acknowledged: Bool
}

struct PiProjectResource: Decodable, Sendable, Equatable, Hashable, Identifiable {
    var id: String { path }
    /// Absolute path pi would load.
    let path: String
    /// Stable, display-friendly kind (e.g. `.pi/extensions`, `.agents/skills`).
    let kind: String
    /// Whether loading this means EXECUTING repo-controlled code at pi startup,
    /// as opposed to feeding it repo-controlled text. Worth saying plainly rather
    /// than calling all of these "config".
    let executesCode: Bool
}

/// One decision in pi's `trust.json`, for review and revocation.
struct PiTrustEntry: Decodable, Sendable, Equatable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let trusted: Bool
}

/// Sentinel Select value that switches the credentials form to custom mode.
let piCustomProviderSentinel = "__custom__"

let piThinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]

/// Wire protocols pi accepts for a custom provider in `models.json`.
let piCustomApiProtocols = ["openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai"]

/// Curated built-in providers (id → brand label). Mirrors the web's `PI_BUILTIN_PROVIDERS`
/// subset of pi's `env-api-keys.ts`. Labels are brand names (not localized). Special-auth
/// providers (azure/bedrock/vertex/…) are omitted — they don't fit the single-key flow.
let piBuiltinProviders: [(id: String, label: String)] = [
    ("anthropic", "Anthropic"),
    ("openai", "OpenAI"),
    ("google", "Google Gemini"),
    ("openrouter", "OpenRouter"),
    ("vercel-ai-gateway", "Vercel AI Gateway"),
    ("xai", "xAI"),
    ("deepseek", "DeepSeek"),
    ("groq", "Groq"),
    ("cerebras", "Cerebras"),
    ("mistral", "Mistral"),
    ("nvidia", "NVIDIA NIM"),
    ("together", "Together AI"),
    ("fireworks", "Fireworks"),
    ("huggingface", "Hugging Face"),
    ("kimi-coding", "Kimi For Coding"),
    ("moonshotai", "Moonshot AI"),
    ("moonshotai-cn", "Moonshot AI (China)"),
    ("zai", "Z.AI Coding Plan (Global)"),
    ("zai-coding-cn", "Z.AI Coding Plan (China)"),
    ("minimax", "MiniMax"),
    ("minimax-cn", "MiniMax (China)"),
    ("ant-ling", "Ant Ling"),
    ("xiaomi", "Xiaomi MiMo"),
    ("xiaomi-token-plan-cn", "Xiaomi MiMo Token Plan (China)"),
    ("xiaomi-token-plan-ams", "Xiaomi MiMo Token Plan (Amsterdam)"),
    ("xiaomi-token-plan-sgp", "Xiaomi MiMo Token Plan (Singapore)"),
    ("opencode", "OpenCode Zen"),
    ("opencode-go", "OpenCode Go"),
]

enum PiConfig {
    /// Build the env map to persist for pi's runtime. `custom` mode writes
    /// PI_ACP_PI_COMMAND (+ optional dir overrides); `default` clears all three so
    /// pi-acp falls back to the `pi` on PATH. Everything else is copied through
    /// untouched — including `PI_ACP_TRUST_WORKSPACE`, the inert leftover of the
    /// launch-time trust seeding an older build may have persisted a `"0"` for.
    /// Mirrors the web `buildPiRuntimeEnv`.
    static func buildRuntimeEnv(_ prevEnv: [String: String], mode: PiRuntimeMode,
                                command: String, configDir: String, sessionDir: String) -> [String: String] {
        var env = prevEnv
        let cmd = command.trimmingCharacters(in: .whitespaces)
        if mode == .custom && !cmd.isEmpty {
            env[PiEnvKeys.command] = cmd
            assign(&env, PiEnvKeys.configDir, configDir)
            assign(&env, PiEnvKeys.sessionDir, sessionDir)
        } else {
            env.removeValue(forKey: PiEnvKeys.command)
            env.removeValue(forKey: PiEnvKeys.configDir)
            env.removeValue(forKey: PiEnvKeys.sessionDir)
        }
        return env
    }

    private static func assign(_ env: inout [String: String], _ key: String, _ value: String) {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { env.removeValue(forKey: key) } else { env[key] = t }
    }
}
