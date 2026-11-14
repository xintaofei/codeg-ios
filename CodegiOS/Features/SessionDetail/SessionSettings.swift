import Foundation

// Pure ports of codeg web's `src/lib/model-config-groups.ts` and
// `src/lib/session-settings.ts` (codeg 0.44): the agent's config options — or
// the legacy mode list, for an agent that publishes no config options —
// normalized into one ordered list that the options button summarizes and the
// options sheet edits. No UI and no I/O; the commits are ``AgentOptionsModel``'s.

// MARK: - Model option groups

/// A visual group of select choices. `name == nil` renders the choices with no
/// header — the leading "floating" bucket of values that carry no `provider/`
/// prefix, or the single group of a flat list.
struct ModelOptionGroup: Hashable, Sendable {
    let key: String
    let name: String?
    let options: [SessionConfigSelectOption]
}

enum ModelOptionGroups {
    /// The id every agent codeg ships publishes its model selector under — a
    /// convention, not an ACP guarantee, hence the category check beside it.
    static let modelOptionId = "model"

    /// Only the model picker groups by `/` prefix. The backend ships it with
    /// `id == "model"` and no category; Codex's approval preset uses
    /// `category == "mode"`. Either signal counts.
    static func isModelOption(_ option: SessionConfigOption) -> Bool {
        option.id == modelOptionId || option.category == "model"
    }

    /// The namespace before the FIRST "/", or nil when there is no usable prefix
    /// (no slash, a leading slash, or a trailing slash with an empty suffix).
    private static func prefix(of value: String) -> String? {
        guard let slash = value.firstIndex(of: "/"), slash != value.startIndex else { return nil }
        let rest = value[value.index(after: slash)...]
        guard !rest.isEmpty else { return nil }
        return String(value[..<slash])
    }

    /// A display name split on its first "/", both sides trimmed; nil when
    /// either side is empty.
    private static func splitNamePrefix(_ name: String) -> (head: String, tail: String)? {
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let head = name[..<slash].trimmingCharacters(in: .whitespaces)
        let tail = name[name.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return (head, tail)
    }

    /// The leading display-name segment EVERY row repeats, or nil.
    private static func sharedNamePrefix(_ items: [SessionConfigSelectOption]) -> String? {
        var shared: String?
        for item in items {
            guard let split = splitNamePrefix(item.name) else { return nil }
            if shared == nil {
                shared = split.head
            } else if shared != split.head {
                return nil
            }
        }
        return shared
    }

    /// The shared prefix worth stripping. A lone row is only stripped when its
    /// name's head IS the value prefix (`anthropic/claude-opus`), so a slashed
    /// display name like `GPT-4o/preview` is not mistaken for a provider.
    private static func strippablePrefix(_ valuePrefix: String, _ items: [SessionConfigSelectOption]) -> String? {
        guard let shared = sharedNamePrefix(items) else { return nil }
        if items.count < 2 && shared != valuePrefix { return nil }
        return shared
    }

    private static func buildGroup(_ valuePrefix: String, _ items: [SessionConfigSelectOption]) -> ModelOptionGroup {
        guard let shared = strippablePrefix(valuePrefix, items) else {
            return ModelOptionGroup(key: valuePrefix, name: valuePrefix, options: items)
        }
        return ModelOptionGroup(
            key: valuePrefix,
            name: shared,
            options: items.map {
                SessionConfigSelectOption(
                    value: $0.value,
                    name: splitNamePrefix($0.name)?.tail ?? $0.name,
                    description: $0.description
                )
            }
        )
    }

    /// `provider/` prefix groups for the model picker's flat value list, or nil
    /// for "render as-is": not the model picker, not a select, server-provided
    /// groups (respected verbatim), or grouping would add nothing. Membership is
    /// by the VALUE's first segment; header and row labels come from the display
    /// name. Values are never rewritten.
    static func derive(_ option: SessionConfigOption) -> [ModelOptionGroup]? {
        guard isModelOption(option), case .select(_, let options, let groups) = option.kind,
              groups.isEmpty else { return nil }
        let prefixes = options.map { prefix(of: $0.value) }
        guard prefixes.contains(where: { $0 != nil }) else { return nil }

        var floating: [SessionConfigSelectOption] = []
        var order: [String] = []
        var byPrefix: [String: [SessionConfigSelectOption]] = [:]
        for (option, prefix) in zip(options, prefixes) {
            guard let prefix else {
                floating.append(option)
                continue
            }
            if byPrefix[prefix] == nil { order.append(prefix) }
            byPrefix[prefix, default: []].append(option)
        }

        // A lone provider with nothing beside it is only worth a header when its
        // rows share a redundant display prefix to strip.
        if order.count == 1 && floating.isEmpty {
            let items = byPrefix[order[0]] ?? []
            guard strippablePrefix(order[0], items) != nil else { return nil }
            return [buildGroup(order[0], items)]
        }

        var result: [ModelOptionGroup] = []
        if !floating.isEmpty {
            result.append(ModelOptionGroup(key: "__ungrouped__", name: nil, options: floating))
        }
        for prefix in order {
            result.append(buildGroup(prefix, byPrefix[prefix] ?? []))
        }
        return result
    }

    /// The groups to render: derived `provider/` groups when applicable, else the
    /// agent's own groups verbatim, else one headerless group. Empty for a
    /// non-select.
    static func listGroups(_ option: SessionConfigOption) -> [ModelOptionGroup] {
        guard case .select(_, let options, let groups) = option.kind else { return [] }
        if let derived = derive(option) { return derived }
        if !groups.isEmpty {
            return groups.map { ModelOptionGroup(key: $0.group, name: $0.name, options: $0.options) }
        }
        return [ModelOptionGroup(key: "__all__", name: nil, options: options)]
    }

    /// Filter by a search query: a case-insensitive substring of the display name
    /// OR the value id. Groups left empty drop out; a blank query changes nothing.
    static func filter(_ groups: [ModelOptionGroup], query: String) -> [ModelOptionGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let options = group.options.filter {
                $0.name.lowercased().contains(q) || $0.value.lowercased().contains(q)
            }
            return options.isEmpty ? nil : ModelOptionGroup(key: group.key, name: group.name, options: options)
        }
    }
}

// MARK: - Session settings

/// One of the agent's settings, as the options button reads it and the sheet
/// edits it.
struct SessionSetting: Hashable, Sendable, Identifiable {
    /// Unique across the list (`config:<id>`, or `mode` for the legacy list).
    let key: String
    let target: AgentOptionsModel.Selector
    let title: String
    let description: String?
    /// What this setting adds to the button's merged label, or nil. A switch
    /// shows its title only while on; a value whose id is `default` shows
    /// nothing — except on the model picker, whose value always shows.
    var summary: String?
    let control: Control

    var id: String { key }

    enum Control: Hashable, Sendable {
        case choice(SessionChoice)
        /// A boolean option, or a two-value on/off select. The values are the
        /// agent's own, sent verbatim (`"true"`/`"false"` for a boolean).
        case toggle(isOn: Bool, onValue: String, offValue: String)
    }

    var choice: SessionChoice? {
        if case .choice(let choice) = control { return choice }
        return nil
    }
}

/// A select setting.
struct SessionChoice: Hashable, Sendable {
    enum Presentation: Hashable, Sendable {
        /// The model picker, or a select with more than
        /// ``SessionSettings/segmentedMax`` values.
        case list
        /// A short select. The web draws a segmented control; this client keeps
        /// its radio rows (see `AgentOptionsSheet`).
        case segmented
    }

    let presentation: Presentation
    /// The `id == "model"` picker, whose search says "models".
    let isModel: Bool
    let currentValue: String
    /// The current value's display name (prefix-stripped when the model list is
    /// grouped by provider), or the raw value when it names no option.
    let currentLabel: String
    let currentDescription: String?
    /// At least one group; a flat list is one headerless group.
    let groups: [ModelOptionGroup]
    /// The agent's recommendation; may name no option, in which case nothing is
    /// marked.
    let recommendedValue: String?
    /// A list past ``SessionSettings/searchThreshold`` values gets a search box.
    let searchable: Bool

    var allOptions: [SessionConfigSelectOption] { groups.flatMap(\.options) }
}

enum SessionSettings {
    /// A list with more options than this is searchable.
    static let searchThreshold = 8
    /// A select with at most this many options is "segmented", unless it is the
    /// model picker, which is always a list.
    static let segmentedMax = 8
    /// A summary part this short (in Unicode scalars, like the web's
    /// `[...summary].length`) never truncates; longer ones give way first.
    static let shortSummaryLength = 8

    static func isShortSummary(_ summary: String) -> Bool {
        summary.unicodeScalars.count <= shortSummaryLength
    }

    private static let onOffPairs: [(on: String, off: String)] = [("on", "off"), ("true", "false")]

    /// A two-option select whose values are on/off reads as a switch (Claude's
    /// and Codex's "Fast mode" arrive as selects) — but only while the current
    /// value is one of the two: Kiro reports `default` for an unset thinking
    /// state, and a switch would claim "off" for it.
    private static func onOffValues(_ option: SessionConfigOption) -> (on: String, off: String)? {
        guard case .select(let current, let options, _) = option.kind, options.count == 2 else { return nil }
        for pair in onOffPairs {
            guard let on = options.first(where: { $0.value.lowercased() == pair.on }),
                  let off = options.first(where: { $0.value.lowercased() == pair.off }) else { continue }
            guard current == on.value || current == off.value else { return nil }
            return (on.value, off.value)
        }
        return nil
    }

    private static func isDefaultValue(_ value: String) -> Bool {
        value.lowercased() == "default"
    }

    /// Model first, then effort, then mode, then everything else in the agent's
    /// own order, then the switches: "Opus 5.5 / High / Plan".
    private static func rank(_ setting: SessionSetting, _ option: SessionConfigOption?) -> Int {
        if case .toggle = setting.control { return 4 }
        if let option, ModelOptionGroups.isModelOption(option) { return 0 }
        // No option = the legacy mode list.
        let category: String? = if let option { option.category } else { "mode" }
        if category == "thought_level" { return 1 }
        if category == "mode" { return 2 }
        return 3
    }

    private static func setting(for option: SessionConfigOption) -> SessionSetting? {
        let key = "config:\(option.id)"
        let target = AgentOptionsModel.Selector.config(id: option.id)
        switch option.kind {
        case .boolean(let isOn):
            return SessionSetting(
                key: key, target: target, title: option.name, description: option.description,
                summary: isOn ? option.name : nil,
                control: .toggle(isOn: isOn, onValue: "true", offValue: "false")
            )
        case .select(let currentValue, let options, _):
            if let onOff = onOffValues(option) {
                let isOn = currentValue == onOff.on
                return SessionSetting(
                    key: key, target: target, title: option.name, description: option.description,
                    summary: isOn ? option.name : nil,
                    control: .toggle(isOn: isOn, onValue: onOff.on, offValue: onOff.off)
                )
            }
            let groups = ModelOptionGroups.listGroups(option)
            let current = groups.lazy.flatMap(\.options).first { $0.value == currentValue }
            let currentLabel = current?.name ?? currentValue
            let isModel = option.id == ModelOptionGroups.modelOptionId
            let isList = isModel || options.count > segmentedMax
            let choice = SessionChoice(
                presentation: isList ? .list : .segmented,
                isModel: isModel,
                currentValue: currentValue,
                currentLabel: currentLabel,
                currentDescription: current?.description,
                groups: groups,
                recommendedValue: option.recommendedValue,
                searchable: isList && options.count > searchThreshold
            )
            let shows = ModelOptionGroups.isModelOption(option) || !isDefaultValue(currentValue)
            return SessionSetting(
                key: key, target: target, title: option.name, description: option.description,
                summary: shows ? currentLabel : nil,
                control: .choice(choice)
            )
        case .unknown:
            return nil
        }
    }

    private static func legacyModeSetting(_ modes: [SessionModeInfo], currentModeId: String, title: String) -> SessionSetting {
        let options = modes.map { SessionConfigSelectOption(value: $0.id, name: $0.name, description: $0.description) }
        let current = options.first { $0.value == currentModeId }
        let currentLabel = current?.name ?? currentModeId
        let isList = options.count > segmentedMax
        let choice = SessionChoice(
            presentation: isList ? .list : .segmented,
            isModel: false,
            currentValue: currentModeId,
            currentLabel: currentLabel,
            currentDescription: current?.description,
            groups: [ModelOptionGroup(key: "__modes__", name: nil, options: options)],
            recommendedValue: nil,
            searchable: isList && options.count > searchThreshold
        )
        return SessionSetting(
            key: "mode", target: .mode, title: title, description: nil,
            summary: isDefaultValue(currentModeId) ? nil : currentLabel,
            control: .choice(choice)
        )
    }

    /// The web's `buildSessionSettings`. Pass `modes` only when the legacy mode
    /// list IS the agent's selector (it publishes no config options).
    static func build(
        configOptions: [SessionConfigOption],
        modes: [SessionModeInfo],
        currentModeId: String?,
        modeTitle: String
    ) -> [SessionSetting] {
        var ranked: [(setting: SessionSetting, rank: Int, index: Int)] = []
        for option in configOptions {
            if let setting = setting(for: option) {
                ranked.append((setting, rank(setting, option), ranked.count))
            }
        }
        if !modes.isEmpty, let currentModeId {
            let setting = legacyModeSetting(modes, currentModeId: currentModeId, title: modeTitle)
            ranked.append((setting, rank(setting, nil), ranked.count))
        }
        var settings = ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
            .map(\.setting)
        // Everything left out (Gemini, on its `default` mode only): a bare icon
        // would say nothing, so the first non-switch value shows.
        if !settings.contains(where: { $0.summary != nil }),
           let index = settings.firstIndex(where: { $0.choice != nil }),
           let choice = settings[index].choice {
            settings[index].summary = choice.currentLabel
        }
        return settings
    }

    /// The settings as this client holds them: the catalog on screen with the
    /// model's (possibly optimistic) selection laid over each current value.
    ///
    /// Mirrors the sheet's gates: only options this build can draw
    /// (``SessionConfigKind/isRenderable``), and the legacy modes only when no
    /// such option exists (the web's `hasModes && !hasConfigOptions`).
    static func build(
        snapshot: AgentOptionsSnapshot,
        selectedModeId: String?,
        selectedConfig: [String: String],
        modeTitle: String
    ) -> [SessionSetting] {
        let configOptions = snapshot.configOptions
            .filter { $0.kind.isRenderable }
            .map { option -> SessionConfigOption in
                guard let selected = selectedConfig[option.id] else { return option }
                return option.overridingCurrentValue(selected)
            }
        let modes = configOptions.isEmpty ? (snapshot.modes?.availableModes ?? []) : []
        return build(
            configOptions: configOptions,
            modes: modes,
            currentModeId: selectedModeId ?? snapshot.modes?.currentModeId,
            modeTitle: modeTitle
        )
    }

    /// The parts the button shows, in order.
    static func summaryParts(_ settings: [SessionSetting]) -> [String] {
        settings.compactMap(\.summary)
    }

    /// The button's spoken value: every setting, including the ones the visible
    /// label leaves out (a `default` value, a switch that is off), as
    /// "Model Opus 5.5, Fast mode Off".
    static func accessibilityValue(_ settings: [SessionSetting], on: String, off: String) -> String {
        settings.map { setting in
            let value: String
            switch setting.control {
            case .choice(let choice): value = choice.currentLabel
            case .toggle(let isOn, _, _): value = isOn ? on : off
            }
            return "\(setting.title) \(value)"
        }
        .joined(separator: ", ")
    }
}

extension SessionConfigOption {
    /// This option with `value` as its current value (the client's selection,
    /// in the selector transport's string form — see ``SessionConfigKind``).
    func overridingCurrentValue(_ value: String) -> SessionConfigOption {
        let kind: SessionConfigKind
        switch self.kind {
        case .select(_, let options, let groups):
            kind = .select(currentValue: value, options: options, groups: groups)
        case .boolean:
            kind = .boolean(currentValue: value == "true")
        case .unknown:
            return self
        }
        return SessionConfigOption(
            id: id, name: name, description: description, category: category,
            kind: kind, recommendedValue: recommendedValue
        )
    }
}
