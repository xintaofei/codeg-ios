import Foundation

/// Decode-only models for the compose-bar "+" menu's insert sources, mirroring
/// the web client's add-menu (`message-input.tsx`): Quick Messages, Expert
/// Skills, and Slash Commands. Responses are snake_case and decoded with
/// `.convertFromSnakeCase`, so properties are plain camelCase with NO snake
/// `CodingKeys` (adding them would double-convert and break the decode).

// MARK: - Quick Messages

/// A reusable message template (`quick_messages_list` → Rust `QuickMessageInfo`).
/// Selecting one inserts its `content` into the draft.
struct QuickMessage: Decodable, Hashable, Sendable, Identifiable {
    let id: Int
    let title: String
    let content: String
    let sortOrder: Int

    private enum CodingKeys: String, CodingKey {
        case id, title, content, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    init(id: Int, title: String, content: String, sortOrder: Int) {
        self.id = id; self.title = title; self.content = content; self.sortOrder = sortOrder
    }
}

// MARK: - Expert Skills

/// One expert/skill linked to an agent (`experts_list_for_agent` →
/// Rust `ExpertListItem`). We only need its metadata to render + insert.
struct ExpertListItem: Decodable, Hashable, Sendable, Identifiable {
    let metadata: ExpertMetadata
    var id: String { metadata.id }
}

/// Expert metadata (Rust `ExpertMetadata`). `displayName`/`description` are
/// locale maps (e.g. `{"en": "...", "zh": "..."}`) — the map keys are data, not
/// coding keys, so the snake_case decoder leaves them untouched.
struct ExpertMetadata: Decodable, Hashable, Sendable {
    let id: String
    let category: String
    let icon: String?
    let sortOrder: Int
    let displayName: [String: String]
    let description: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id, category, icon, sortOrder, displayName, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        displayName = try c.decodeIfPresent([String: String].self, forKey: .displayName) ?? [:]
        description = try c.decodeIfPresent([String: String].self, forKey: .description) ?? [:]
    }

    init(id: String, category: String, icon: String?, sortOrder: Int,
         displayName: [String: String], description: [String: String]) {
        self.id = id; self.category = category; self.icon = icon
        self.sortOrder = sortOrder; self.displayName = displayName; self.description = description
    }

    /// Localized display name, mirroring the web's `pickExpertLocalized`: prefer
    /// the current language, then an `en` fallback, then any non-empty value,
    /// finally the id.
    var localizedName: String { Self.pick(displayName) ?? id }
    /// Localized description, or nil when none is provided.
    var localizedDescription: String? { Self.pick(description) }

    /// Mirrors the web's `pickExpertLocalized`: try the full region-qualified
    /// locale first (so `zh-CN` beats `zh-TW`), then the language, then `en`, then
    /// any entry — but resolved deterministically (case-insensitive, sorted keys)
    /// rather than relying on dictionary iteration order.
    private static func pick(_ map: [String: String]) -> String? {
        guard !map.isEmpty else { return nil }
        // key (lowercased) -> value, dropping empties; ties resolved by sorted key.
        var lower: [String: String] = [:]
        for key in map.keys.sorted() {
            guard let v = map[key], !v.isEmpty else { continue }
            let lk = key.lowercased()
            if lower[lk] == nil { lower[lk] = v }
        }
        let loc = Locale.current
        let lang = loc.language.languageCode?.identifier.lowercased()
        var candidates = [loc.identifier.replacingOccurrences(of: "_", with: "-").lowercased()]
        if let lang, let region = loc.region?.identifier { candidates.append("\(lang)-\(region.lowercased())") }
        if let lang { candidates.append(lang) }
        candidates.append("en")
        for candidate in candidates {
            if let v = lower[candidate] { return v }
        }
        // Deterministic language-prefix fallback (user "zh"; keys "zh-CN"/"zh-TW").
        if let lang {
            for key in lower.keys.sorted() where key.split(separator: "-").first.map(String.init) == lang {
                return lower[key]
            }
        }
        return lower.keys.sorted().first.flatMap { lower[$0] }
    }
}

// MARK: - Slash Commands

/// A slash command the live agent advertises (`available_commands` in the live
/// session snapshot → Rust `AvailableCommandInfo`). Selecting one inserts its
/// invocation token (``ComposerInvocations/commandInvocationToken(_:)``) —
/// `/<name>`, or the bare `$<skill>` Codex names its skills-as-commands.
struct AvailableCommandInfo: Decodable, Hashable, Sendable, Identifiable {
    let name: String
    let description: String
    let inputHint: String?
    /// The agent marks the command as a skill (claude-agent-acp, JetBrains
    /// AIR). Absent on the wire when false.
    var skill: Bool = false
    /// The skill's `SKILL.md`, when the agent sent it. Only set with `skill`.
    var skillPath: String? = nil

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputHint
        case skill, skillPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputHint = try c.decodeIfPresent(String.self, forKey: .inputHint)
        skill = ((try? c.decodeIfPresent(Bool.self, forKey: .skill)) ?? nil) ?? false
        skillPath = (try? c.decodeIfPresent(String.self, forKey: .skillPath)) ?? nil
    }

    init(name: String, description: String, inputHint: String?, skill: Bool = false, skillPath: String? = nil) {
        self.name = name; self.description = description; self.inputHint = inputHint
        self.skill = skill; self.skillPath = skillPath
    }
}
