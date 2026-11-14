import Foundation

// The composer's inline triggers — `/` (and Codex's `$`) for the command and
// skill menu, `@` for the mention panel — ported from web
// `src/components/chat/message-input.tsx` (`detectSlashTrigger`),
// `composer/suggestion/mention-match.ts` and `composer/invocation-reference.ts`.
//
// Everything here works in UTF-16 code units, which is what the web's offsets
// and regexes measure, and what the caret is converted to the moment the text
// field reports it.

/// What a JavaScript regex `\s` matches: ECMAScript WhiteSpace plus
/// LineTerminator. Spelled out because Foundation's and ICU's notions of
/// whitespace differ from it at the edges (U+000B, U+FEFF, U+0085).
enum JSWhitespace {
    static func contains(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        case 0x2000...0x200A:
            return true
        default:
            return false
        }
    }
}

/// The prefix a disk skill or command is invoked by.
enum InvocationPrefix: String, Hashable, Sendable {
    case slash = "/"
    case dollar = "$"

    var unit: UInt16 { self == .slash ? 0x2F : 0x24 }
}

// MARK: - Mention start rule

/// Where a typed `@` may open the mention panel (web `canStartMentionAt`).
enum MentionStart {
    /// The scripts written without spaces between words. ICU's `Script=`
    /// property is the same Unicode `Script` the web's `\p{Script=…}` reads
    /// (not `Script_Extensions`, which would admit combining marks).
    private static let spacelessScripts = try? NSRegularExpression(
        pattern: #"^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Bopomofo}]$"#)

    /// One code point after which a typed `@` may still open the panel:
    /// whitespace, the spaceless scripts above, the punctuation blocks they
    /// use (CJK Symbols and Punctuation, CJK Compatibility Forms,
    /// Halfwidth/Fullwidth Forms), and four `Script=Common` marks CJK words
    /// end on (· ゠ ・ ー). ASCII letters, digits and punctuation are absent on
    /// purpose: `me@x.com` must not open a file picker.
    static func isAllowedPrefix(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v <= 0xFFFF, JSWhitespace.contains(UInt16(v)) { return true }
        switch v {
        case 0x3000...0x303F, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
             0x00B7, 0x30A0, 0x30FB, 0x30FC:
            return true
        default:
            break
        }
        guard v > 0x7F else { return false }
        guard let regex = spacelessScripts else {
            return fallbackSpacelessBlocks.contains { $0.contains(v) }
        }
        let s = String(Character(scalar))
        return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// The blocks those scripts live in — only consulted if ICU ever rejects
    /// the property pattern above, so the panel still opens after CJK text.
    private static let fallbackSpacelessBlocks: [ClosedRange<UInt32>] = [
        0x02EA...0x02EB, 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3040...0x312F,
        0x3130...0x318F, 0x31A0...0x31FF, 0x3200...0x33FF, 0x3400...0x4DBF,
        0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
        0x1B000...0x1B16F, 0x20000...0x3FFFF,
    ]

    /// May a mention start at `index` (the UTF-16 offset of the `@`) in `units`?
    /// True at the very start. Steps back a whole code point, so a Han
    /// character beyond the BMP counts as the one character it is.
    static func canStart(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        guard index <= units.count else { return false }
        let unit = units[index - 1]
        let scalar: Unicode.Scalar?
        if UTF16.isTrailSurrogate(unit), index >= 2, UTF16.isLeadSurrogate(units[index - 2]) {
            let lead = UInt32(units[index - 2]) - 0xD800
            let trail = UInt32(unit) - 0xDC00
            scalar = Unicode.Scalar(0x10000 + (lead << 10) + trail)
        } else {
            scalar = Unicode.Scalar(unit)
        }
        guard let scalar else { return false }
        return isAllowedPrefix(scalar)
    }

    static func canStart(_ text: String, at index: Int) -> Bool {
        canStart(Array(text.utf16), at: index)
    }
}

// MARK: - Invocation helpers

/// Web `invocation-reference.ts`: which agents get disk skills, under which
/// trigger, and the literal token a command runs as.
enum ComposerInvocations {
    /// The trigger under which the menu lists an agent's skills read from disk,
    /// or nil when the agent advertises its skills as commands itself.
    ///
    /// - Codex: `$`, its own skill-mention syntax.
    /// - Antigravity, OpenCode: `/`, beside their commands (their ACP servers
    ///   advertise only commands, never a skill).
    /// - Custom ACP agents: `/` — codeg cannot tell what an arbitrary server
    ///   advertises, so the scan follows the skill directories the user
    ///   declared for it.
    static func diskSkillTrigger(_ agent: AgentType?) -> InvocationPrefix? {
        guard let agent else { return nil }
        if agent == .codex { return .dollar }
        if agent == .openCode || agent.rawValue == "antigravity" || agent.isCustom { return .slash }
        return nil
    }

    /// The literal token an advertised command executes as. Codex advertises
    /// its skills as commands NAMED `$<skill>`, whose `$` is the prefix — so
    /// nothing is prepended; every other command runs as `/<name>`.
    static func commandInvocationToken(_ name: String) -> String {
        name.hasPrefix("$") ? name : "/\(name)"
    }

    /// What the agent says goes after a command, or nil when it advertises
    /// nothing to type there.
    static func commandInputHint(_ command: AvailableCommandInfo) -> String? {
        guard let hint = command.inputHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty else { return nil }
        return hint
    }

    /// The disk skills a menu offers under `trigger`. Under `/` they share the
    /// menu with the agent's commands, and a skill whose `/<id>` is also a
    /// command is left out — sending that token runs the command.
    static func skillsForMenu(
        _ skills: [AgentSkillItem], commands: [AvailableCommandInfo], trigger: InvocationPrefix
    ) -> [AgentSkillItem] {
        guard trigger == .slash, !commands.isEmpty else { return skills }
        let tokens = Set(commands.map { commandInvocationToken($0.name) })
        return skills.filter { !tokens.contains("/\($0.id)") }
    }

    /// The names of the commands a menu marks as skills, or none. The marks
    /// count only in a list that has a skill WITHOUT a path: claude-agent-acp
    /// marks skills in two passes and only the second (after Claude Code's own
    /// skill list was read) marks them all, so an earlier list would show some
    /// skills marked and others not.
    static func skillMarkedCommands(_ commands: [AvailableCommandInfo]) -> Set<String> {
        guard commands.contains(where: { $0.skill && ($0.skillPath ?? "").isEmpty }) else { return [] }
        return Set(commands.filter(\.skill).map(\.name))
    }
}

// MARK: - Trigger detection

/// The trigger the caret sits in, if any. Ranges are UTF-16 offsets into the
/// text the trigger was detected in: the `/`·`$`·`@` character through the
/// caret — exactly what a selection replaces.
enum ComposerTrigger: Equatable, Sendable {
    case command(prefix: InvocationPrefix, query: String, range: Range<Int>)
    case mention(query: String, range: Range<Int>)

    var range: Range<Int> {
        switch self {
        case .command(_, _, let range), .mention(_, let range): return range
        }
    }

    var query: String {
        switch self {
        case .command(_, let query, _), .mention(let query, _): return query
        }
    }

    static func detect(text: String, caretUTF16: Int, agent: AgentType?) -> ComposerTrigger? {
        detect(text: text, caretUTF16: caretUTF16, skillTrigger: ComposerInvocations.diskSkillTrigger(agent))
    }

    /// Both triggers read the text before the caret. When both match (only
    /// possible across a CJK boundary, e.g. `/文@x`), the one nearer the caret
    /// is the one being typed.
    static func detect(text: String, caretUTF16: Int, skillTrigger: InvocationPrefix?) -> ComposerTrigger? {
        let units = Array(text.utf16)
        guard caretUTF16 >= 0, caretUTF16 <= units.count else { return nil }
        let command = detectCommand(units, caret: caretUTF16, skillTrigger: skillTrigger)
        let mention = detectMention(units, caret: caretUTF16)
        switch (command, mention) {
        case let (c?, m?): return m.range.lowerBound > c.range.lowerBound ? m : c
        case let (c?, nil): return c
        case let (nil, m?): return m
        default: return nil
        }
    }

    /// Web `(^|\s)(\/)(\S*)$` — or `(^|\s)([/$])(\S*)$` when the agent's disk
    /// skills are triggered by `$` — against the text before the caret: the
    /// run of non-whitespace ending at the caret must open with the trigger.
    /// Mid-text after whitespace counts, as on the web.
    static func detectCommand(_ units: [UInt16], caret: Int, skillTrigger: InvocationPrefix?) -> ComposerTrigger? {
        var start = caret
        while start > 0, !JSWhitespace.contains(units[start - 1]) { start -= 1 }
        guard start < caret else { return nil }
        let first = units[start]
        let prefix: InvocationPrefix
        if first == InvocationPrefix.slash.unit {
            prefix = .slash
        } else if skillTrigger == .dollar, first == InvocationPrefix.dollar.unit {
            prefix = .dollar
        } else {
            return nil
        }
        let query = String(decoding: units[(start + 1)..<caret], as: UTF16.self)
        return .command(prefix: prefix, query: query, range: start..<caret)
    }

    /// Tiptap's suggestion matcher with `allowSpaces: false` plus the web's
    /// prefix rule: the last `@` before the caret, no whitespace between it and
    /// the caret, and a character before it that may start a mention.
    static func detectMention(_ units: [UInt16], caret: Int) -> ComposerTrigger? {
        var at = caret - 1
        while at >= 0 {
            let unit = units[at]
            if unit == 0x40 { break }
            if JSWhitespace.contains(unit) { return nil }
            at -= 1
        }
        guard at >= 0, MentionStart.canStart(units, at: at) else { return nil }
        let query = String(decoding: units[(at + 1)..<caret], as: UTF16.self)
        return .mention(query: query, range: at..<caret)
    }
}

// MARK: - Edits

/// A replacement in the composer's text, in UTF-16 offsets, plus where the
/// caret goes afterwards.
struct ComposerEdit: Equatable, Sendable {
    let range: Range<Int>
    let replacement: String

    var caretAfter: Int { range.lowerBound + replacement.utf16.count }

    /// Nil when the range no longer fits the text (it changed underneath).
    func apply(to text: String) -> String? {
        var units = Array(text.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
        units.replaceSubrange(range, with: Array(replacement.utf16))
        return String(decoding: units, as: UTF16.self)
    }
}
