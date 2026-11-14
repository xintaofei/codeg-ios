import Foundation

/// The agent's configurable options as enumerated by `acp_describe_agent_options`
/// (Rust `AgentOptionsSnapshot`). Decode-only.
///
/// IMPORTANT: this catalog comes from a server-side *probe* agent the route
/// spawns on demand, NOT from the live chat connection. So `modes.currentModeId`
/// and a select's `currentValue` are the probe's fresh-session **defaults** — a
/// reasonable initial highlight, but not a claim about the live session's state.
/// Applying a choice (`acp_set_mode` / `acp_set_config_option`) targets the chat
/// connection separately.
///
/// Responses are decoded with `.convertFromSnakeCase`, so wire keys like
/// `config_options` arrive here already camelCased — properties are spelled in
/// camelCase and must NOT carry snake_case `CodingKeys` (that would double-convert).
struct AgentOptionsSnapshot: Hashable, Sendable, Decodable {
    let modes: SessionModeState?
    let configOptions: [SessionConfigOption]
    /// What the probe's session said it accepts in a prompt. Nil when the agent
    /// advertised nothing within the probe's window.
    let promptCapabilities: PromptCapabilities?
    /// The slash commands the probe's session advertised (empty when it named
    /// none within the probe's window) — how a draft, which has no live
    /// session, still gets a `/` menu.
    let availableCommands: [AvailableCommandInfo]

    private enum CodingKeys: String, CodingKey {
        case modes, configOptions, promptCapabilities
        case availableCommands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = try c.decodeIfPresent(SessionModeState.self, forKey: .modes)
        // Rust always serializes the Vec, but default to empty defensively so a
        // server that omits it can't fail the whole decode.
        configOptions = try c.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions) ?? []
        promptCapabilities = try c.decodeIfPresent(PromptCapabilities.self, forKey: .promptCapabilities)
        // `#[serde(default)]` server-side; a shape surprise must not take the
        // modes and config down with it.
        availableCommands = ((try? c.decodeIfPresent([AvailableCommandInfo].self, forKey: .availableCommands)) ?? nil) ?? []
    }

    /// Direct initializer for previews / tests.
    init(modes: SessionModeState?, configOptions: [SessionConfigOption], promptCapabilities: PromptCapabilities? = nil,
         availableCommands: [AvailableCommandInfo] = []) {
        self.modes = modes
        self.configOptions = configOptions
        self.promptCapabilities = promptCapabilities
        self.availableCommands = availableCommands
    }

    /// True when there is nothing the user can pick — used to show a
    /// "no configurable options" state instead of empty pickers.
    ///
    /// Counts only options this build can DRAW (see ``SessionConfigKind/isRenderable``):
    /// an agent advertising nothing but a kind newer than this app would
    /// otherwise land on the loaded state and render an empty card. Saying "no
    /// configurable options" understates that case slightly — there are options,
    /// just none reachable from this version — but it beats a blank sheet.
    var isEmpty: Bool {
        (modes?.availableModes.isEmpty ?? true) && !configOptions.contains { $0.kind.isRenderable }
    }
}

/// Mode state for the session (Rust `SessionModeStateInfo`): the current mode id
/// plus the list of selectable modes.
struct SessionModeState: Hashable, Sendable, Decodable {
    let currentModeId: String
    let availableModes: [SessionModeInfo]
}

/// The subset of the live session snapshot (`acp_get_session_snapshot_by_conversation`
/// → Rust `LiveSessionSnapshot`) we care about: the AUTHORITATIVE current
/// mode/config for the conversation's live chat session. Unlike the probe
/// (`describe_agent_options`), this reflects the real session state, so it's used
/// both to load the sheet and to reconcile after an apply. Decode-only; the many
/// other snapshot fields are ignored.
struct SessionSnapshot: Hashable, Sendable, Decodable {
    let modes: SessionModeState?
    let currentMode: String?
    let configOptions: [SessionConfigOption]?
    let selectorsReady: Bool
    /// Slash commands the live agent advertises (`available_commands`). Empty
    /// until a connection is bound to the conversation; surfaced in the "+" menu.
    let availableCommands: [AvailableCommandInfo]
    /// What THIS live session accepts in a prompt — the authoritative source for
    /// encoding an attached image (see ``PromptCapabilities``). Nil until the
    /// agent's `initialize` handshake has published them.
    let promptCapabilities: PromptCapabilities?
    /// The connection's own lifecycle state. Read only to stop waiting on a
    /// connection that has already died; an unrecognized value decodes to nil,
    /// which means "keep waiting" — the safe direction.
    let status: ConnectionStatus?
    /// The live-feedback channels this session has (see ``FeedbackItem``).
    /// Nil when the server omits them — an older one — which must never read
    /// as a downgrade.
    let feedbackToolAvailable: Bool?
    let nativeSteeringAvailable: Bool?
    /// The connection's running list and predicted next prompt, as the WS
    /// snapshot carries them (see ``ConnectionRunsSnapshot``).
    let runs: ConnectionRunsSnapshot
    /// Whether the agent has `session/fork` — an answer only once the
    /// connection is initialized (see ``ForkSupport``). Nil when omitted.
    let forkSupported: Bool?

    private enum CodingKeys: String, CodingKey {
        case modes, currentMode, configOptions, selectorsReady, availableCommands
        case promptCapabilities, status
        case feedbackToolAvailable, nativeSteeringAvailable
        case forkSupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = try c.decodeIfPresent(SessionModeState.self, forKey: .modes)
        currentMode = try c.decodeIfPresent(String.self, forKey: .currentMode)
        configOptions = try c.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        selectorsReady = try c.decodeIfPresent(Bool.self, forKey: .selectorsReady) ?? false
        availableCommands = try c.decodeIfPresent([AvailableCommandInfo].self, forKey: .availableCommands) ?? []
        promptCapabilities = try c.decodeIfPresent(PromptCapabilities.self, forKey: .promptCapabilities)
        status = try c.decodeIfPresent(String.self, forKey: .status).flatMap(ConnectionStatus.init(rawValue:))
        feedbackToolAvailable = try? c.decodeIfPresent(Bool.self, forKey: .feedbackToolAvailable)
        nativeSteeringAvailable = try? c.decodeIfPresent(Bool.self, forKey: .nativeSteeringAvailable)
        runs = ConnectionRunsSnapshot.lenient(from: decoder)
        forkSupported = try? c.decodeIfPresent(Bool.self, forKey: .forkSupported)
    }

    /// True when this session is over, so nothing more will ever be published on
    /// it. Mirrors the give-up condition in the backend's own capability wait.
    var isConnectionOver: Bool {
        status == .disconnected || status == .error
    }

    /// True when the snapshot actually carries selectable options (a live session
    /// whose selectors have populated).
    var hasSelectors: Bool {
        !(modes?.availableModes.isEmpty ?? true) || !(configOptions?.isEmpty ?? true)
    }

    /// View as the catalog shape the sheet renders.
    var asOptionsSnapshot: AgentOptionsSnapshot {
        AgentOptionsSnapshot(
            modes: modes,
            configOptions: configOptions ?? [],
            promptCapabilities: promptCapabilities
        )
    }
}

/// What an agent accepts in a prompt (Rust `PromptCapabilitiesInfo`, from the
/// ACP `initialize` handshake). Decode-only.
///
/// This decides how an attached image is put on the wire, because the same bytes
/// have two encodings and agents disagree about which they take:
///
/// - `image` — a native ACP `image` block (Claude, Codex, …).
/// - `embeddedContext` — a `resource` block whose `blob` carries the bytes under
///   an image mime type. Grok advertises `image: false` + `embedded_context: true`
///   and only accepts this form.
///
/// An agent that advertises neither has no third shape to reach for; see
/// ``Attachment/promptInputBlock(for:)``.
struct PromptCapabilities: Hashable, Sendable, Decodable {
    let image: Bool
    /// Decoded for a faithful mirror of the wire struct; this client attaches no
    /// audio, so nothing reads it yet.
    let audio: Bool
    let embeddedContext: Bool

    private enum CodingKeys: String, CodingKey {
        case image, audio, embeddedContext
    }

    init(image: Bool, audio: Bool = false, embeddedContext: Bool) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
    }

    /// Rust serializes all three (plain bools, no `Option`), but default each
    /// defensively: this rides inside ``SessionSnapshot``, and throwing here
    /// would fail the whole snapshot — taking modes, config and slash commands
    /// down with it — over a field nothing but attachment routing reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(Bool.self, forKey: .image) ?? false
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? false
        embeddedContext = try c.decodeIfPresent(Bool.self, forKey: .embeddedContext) ?? false
    }

    /// Whether an image can reach this agent in *any* encoding — the gate on
    /// offering image attachment at all.
    var canAttachImages: Bool { image || embeddedContext }
}

/// One selectable agent mode (Rust `SessionModeInfo`), e.g. Claude's
/// "default" / "plan" modes.
struct SessionModeInfo: Hashable, Sendable, Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

/// One configurable option (Rust `SessionConfigOptionInfo`), e.g. a model
/// selector or an on/off toggle. `kind` carries the concrete control.
struct SessionConfigOption: Hashable, Sendable, Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let kind: SessionConfigKind
    /// The value the AGENT recommends (`recommended_value`, JetBrains AIR's
    /// `recommendedValue` — codex-acp 1.11.0+ and claude-agent-acp 0.76.0+ name
    /// their default model and that model's default effort). A hint only:
    /// `kind`'s current value still says what is selected, and a recommendation
    /// that names no option marks nothing. Absent for agents that publish none
    /// and on servers predating the field (a synthesized optional decodes to nil).
    var recommendedValue: String? = nil
}

/// The control behind a `SessionConfigOption` (Rust `SessionConfigKindInfo`,
/// internally tagged by `type`). Unknown future kinds decode to `.unknown`
/// rather than throwing — the server only strips discriminators *it* cannot
/// decode, so a kind newer than this build can still reach us.
///
/// VALUES ARE OPAQUE STRINGS. The whole selector transport — the set command,
/// `acp_connect`'s `preferredConfigValues`, and ``SelectorPrefsStore`` — carries
/// `String` values; only the server's `encode_config_option_value` turns a
/// boolean's `"true"` back into a real JSON boolean at the ACP wire. So a
/// boolean option's value is exactly `"true"` / `"false"` everywhere here.
enum SessionConfigKind: Hashable, Sendable, Decodable {
    case select(currentValue: String, options: [SessionConfigSelectOption], groups: [SessionConfigSelectGroup])
    /// An on/off toggle (ACP's `unstable_boolean_config`). Cline 3.0.50+ ships
    /// one as `auto_approve` ("Auto-approve tools").
    case boolean(currentValue: Bool)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, currentValue, options, groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "select":
            self = .select(
                currentValue: try c.decodeIfPresent(String.self, forKey: .currentValue) ?? "",
                options: try c.decodeIfPresent([SessionConfigSelectOption].self, forKey: .options) ?? [],
                groups: try c.decodeIfPresent([SessionConfigSelectGroup].self, forKey: .groups) ?? []
            )
        case "boolean":
            // Same `current_value` key as a select, but a JSON bool.
            self = .boolean(currentValue: try c.decodeIfPresent(Bool.self, forKey: .currentValue) ?? false)
        default:
            self = .unknown(type: type)
        }
    }

    /// Whether there is actually a control to draw for this option. False for a
    /// kind this build doesn't model, and for a select that offers no choices —
    /// both render nothing, so counting them would silently hide the Mode section
    /// (suppressed whenever config options exist) and leave an empty card behind.
    var isRenderable: Bool {
        switch self {
        case .select(_, let options, let groups): return !options.isEmpty || !groups.isEmpty
        case .boolean: return true
        case .unknown: return false
        }
    }

    /// Convenience: the flat option list for a `select` (ignoring grouping),
    /// nil for any other kind.
    var selectOptions: [SessionConfigSelectOption]? {
        if case .select(_, let options, _) = self { return options }
        return nil
    }

    /// The grouped option list for a `select`, nil for any other kind. When this
    /// is non-empty the UI must render groups and IGNORE `selectOptions` (the web
    /// renders `groups.length > 0 ? groups : options`, never both).
    var selectGroups: [SessionConfigSelectGroup]? {
        if case .select(_, _, let groups) = self { return groups }
        return nil
    }

    /// The option's current value in the selector transport's string form (see
    /// the type's note), exactly as the agent reports it — including the empty
    /// string a select may normalize to. Nil only for a kind this build cannot
    /// read a value out of.
    ///
    /// Callers that SEED a selection additionally reject the empty string (there
    /// is no such choice to highlight); reconciliation must not, or an agent that
    /// answers `""` would leave the optimistic pick on screen forever.
    var currentValueString: String? {
        switch self {
        case .select(let value, _, _): return value
        case .boolean(let isOn): return isOn ? "true" : "false"
        case .unknown: return nil
        }
    }

    /// Whether `value` is one this option can actually take — used to validate a
    /// cached preference against the live catalog before pre-selecting it.
    func accepts(_ value: String) -> Bool {
        switch self {
        case .select(_, let options, let groups):
            return options.contains { $0.value == value }
                || groups.contains { $0.options.contains { $0.value == value } }
        case .boolean:
            return value == "true" || value == "false"
        case .unknown:
            return false
        }
    }
}

/// One choice in a `select` config option (Rust `SessionConfigSelectOptionInfo`).
struct SessionConfigSelectOption: Hashable, Sendable, Decodable, Identifiable {
    let value: String
    let name: String
    let description: String?

    var id: String { value }
}

/// A named grouping of select options (Rust `SessionConfigSelectGroupInfo`).
struct SessionConfigSelectGroup: Hashable, Sendable, Decodable, Identifiable {
    let group: String
    let name: String
    let options: [SessionConfigSelectOption]

    var id: String { group }
}
