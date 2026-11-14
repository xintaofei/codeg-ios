import Foundation
import SwiftUI

// MARK: - Permission options (Rust `PermissionOptionInfo`)

/// One choice the user can pick to resolve a `permission_request`. `kind` is the
/// SACP permission-option kind (`allow_once` / `allow_always` / `reject_once` /
/// `reject_always`); a `reject*` option is the deny / "keep planning" choice.
struct PermissionOption: Decodable, Hashable, Sendable, Identifiable {
    let optionId: String
    let name: String
    let kind: String
    /// The option's ACP `_meta`, forwarded verbatim (the server names the field
    /// `meta`). codex-acp ≥1.1.8 and claude-agent-acp ≥0.64.1 hang
    /// `permission = {version: 1, changes: [...]}` here — see ``changes``.
    /// Optional: every other agent, and any server older than 0.22.0, omits it.
    let meta: AnyJSON?

    var id: String { optionId }
    /// Deny / keep-planning style choice — rendered as a bordered (non-filled) button.
    var isReject: Bool { kind.lowercased().hasPrefix("reject") }

    /// What picking this option would actually grant, and for how long. Empty
    /// for every agent that ships no `_meta.permission`.
    var changes: [PermissionOptionChange] { PermissionParse.optionChanges(meta) }
}

/// How long a permission change lasts, and where it is written — normalized from
/// the wire's `lifetime: {scope, storage?}` pair into one flat token the card can
/// label directly.
///
/// ``persistent`` is the deliberate catch-all for a `scope: "persistent"` whose
/// `storage` this build does not recognize: the destination is unknown, but the
/// fact that the grant OUTLIVES the session is the part the user must not miss,
/// so it degrades to a weaker warning rather than to silence.
enum PermissionChangeScope: Hashable, Sendable {
    case session
    case process
    case user
    case project
    case projectLocal
    case persistent

    var label: LocalizedStringKey {
        switch self {
        case .session: return "This session"
        case .process: return "This run"
        case .user: return "Saved to user settings"
        case .project: return "Saved to project settings"
        case .projectLocal: return "Saved to local project settings"
        case .persistent: return "Saved permanently"
        }
    }

    /// Grants that outlive the session are the ones worth a warning tint; a
    /// session/run-scoped grant expires on its own and reads as neutral.
    var isPersistent: Bool {
        switch self {
        case .session, .process: return false
        case .user, .project, .projectLocal, .persistent: return true
        }
    }
}

/// One thing an option would change, as the agent itself describes it.
struct PermissionOptionChange: Hashable, Sendable {
    /// The agent's own rendered sentence ("Allow all Bash calls").
    let description: String
    /// `nil` when the change carries no lifetime, reports `scope: "unknown"`, or
    /// uses a scope this build does not know — the card then says nothing about
    /// duration rather than guessing at one.
    let scope: PermissionChangeScope?
}

// MARK: - AskUserQuestion (Rust `QuestionSpec` / `QuestionOption`)

struct QuestionOption: Decodable, Hashable, Sendable {
    let label: String
    let description: String
}

/// One question in an `ask_user_question` set. `id` is the per-question UUID the
/// answer must echo back as `QuestionAnswerItem.questionId`.
struct QuestionSpec: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let question: String
    let header: String
    let multiSelect: Bool
    /// The choices. Empty means free-text: only the typed answer is offered.
    let options: [QuestionOption]
    /// The answer is a secret (codex `request_user_input` marks API keys etc.
    /// with `_meta.codex.isSecret`): the free-text input is masked. Absent on
    /// the wire for every non-secret source.
    let isSecret: Bool
    /// When false, "Other" and its free-text input are hidden. False for native
    /// permission bridges (Antigravity, Pi select) that accept only one of the
    /// given option ids — a typed answer there cannot be delivered. Meaningful
    /// only with options: an option-less question always takes free text.
    let allowOther: Bool

    /// Whether the card offers a typed answer at all.
    var offersFreeText: Bool { allowOther || options.isEmpty }

    init(id: String, question: String, header: String, multiSelect: Bool,
         options: [QuestionOption], isSecret: Bool = false, allowOther: Bool = true) {
        self.id = id
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
        self.isSecret = isSecret
        self.allowOther = allowOther
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, header, multiSelect, options, isSecret, allowOther
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        header = try c.decodeIfPresent(String.self, forKey: .header) ?? ""
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        options = try c.decodeIfPresent([QuestionOption].self, forKey: .options) ?? []
        // Rust: `#[serde(default)]` (false) and `#[serde(default = "default_true")]`.
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        allowOther = try c.decodeIfPresent(Bool.self, forKey: .allowOther) ?? true
    }
}

/// One question's answer: the per-question id plus the chosen option label
/// strings (a free-text "Other" entry is appended verbatim). Encode-only; the
/// request encoder keeps keys camelCase, matching the server's `questionId`.
struct QuestionAnswerItem: Encodable, Sendable {
    let questionId: String
    let labels: [String]
}

/// The full reply to a `question_request`. `declined == true` (with empty
/// `answers`) dismisses the prompt and lets the agent use its own judgment.
struct QuestionAnswer: Encodable, Sendable {
    var answers: [QuestionAnswerItem]
    var declined: Bool

    static let dismissed = QuestionAnswer(answers: [], declined: true)
}

// MARK: - Plan entries (Rust `PlanEntryInfo`)

/// One row of the agent's live plan (`plan_update` event / snapshot `plan` block).
struct PlanEntry: Decodable, Hashable, Sendable {
    let content: String
    let priority: String
    let status: String

    enum Status { case completed, inProgress, pending }
    /// Normalize any raw status string (event, snapshot, or a permission entry's
    /// freeform `status`) to the three render states. Shared so every plan surface
    /// — the live checklist and the ExitPlanMode confirmation — agrees.
    static func status(from raw: String?) -> Status {
        switch (raw ?? "").lowercased() {
        case "completed", "done": return .completed
        case "in_progress", "in-progress", "running", "active": return .inProgress
        default: return .pending
        }
    }
    var normalizedStatus: Status { Self.status(from: status) }

    enum Priority { case high, medium, low }
    var normalizedPriority: Priority {
        switch priority.lowercased() {
        case "high", "urgent": return .high
        case "low": return .low
        default: return .medium
        }
    }

    /// Build from the snapshot's `plan` block, whose `entries` is arbitrary JSON.
    static func list(from json: AnyJSON?) -> [PlanEntry] {
        guard let items = json?.array else { return [] }
        return items.compactMap { item in
            guard let o = item.object else { return nil }
            let content = (o["content"] ?? o["step"] ?? o["title"] ?? o["task"])?.nonEmptyString
            guard let content else { return nil }
            return PlanEntry(
                content: content,
                priority: o["priority"]?.string ?? "medium",
                status: o["status"]?.string ?? (o["state"]?.string ?? "pending")
            )
        }
    }
}

// MARK: - Pending interactive state (held on the view model)

/// A `permission_request` awaiting the user's choice. Also models ExitPlanMode
/// (the plan content rides in `parsed`).
struct PendingPermission: Identifiable {
    let requestId: String
    let parsed: ParsedPermission
    let options: [PermissionOption]
    var id: String { requestId }

    init(requestId: String, toolCall: AnyJSON, options: [PermissionOption]) {
        self.requestId = requestId
        self.parsed = ParsedPermission.parse(toolCall)
        self.options = options
    }
}

/// A `question_request` (`ask_user_question`) awaiting answers.
struct PendingQuestion: Identifiable {
    let questionId: String
    let questions: [QuestionSpec]
    var id: String { questionId }
}

/// A Grok `exit_plan_mode` awaiting the user's decision. Distinct from
/// ``PendingPermission``: Grok's plan approval is its own blocking ext request
/// with three outcomes, not a permission option list. (Claude's ExitPlanMode
/// still arrives as a permission and keeps that path.)
struct PendingPlanApproval: Identifiable {
    let approvalId: String
    /// Grok's `toolCallId` for the `exit_plan_mode` call. Not used for the answer
    /// (which keys on `approvalId`) — kept so the card can correlate with the
    /// suppressed in-stream tool call.
    let toolCallId: String
    /// The plan, read from Grok's `plan.md`. May be empty — the card then shows an
    /// empty-state notice rather than hiding, since the turn is blocked either way.
    let planMarkdown: String
    var id: String { approvalId }
}

/// The user's decision on a pending plan approval. snake_case on the wire.
enum PlanApprovalDecision: String, Encodable, Sendable {
    /// Grok leaves plan mode and starts implementing.
    case approve
    /// Grok revises the plan; plan mode stays active.
    case requestChanges = "request_changes"
    /// Plan mode is turned off.
    case abandon
}

// MARK: - Permission tool-call parsing (port of web `parsePermissionToolCall`)

struct PermissionPlanEntry: Hashable, Sendable {
    let text: String
    let status: String?
}

struct PermissionAllowedPrompt: Hashable, Sendable {
    let prompt: String
    let tool: String
}

/// Everything the permission card needs, extracted from the freeform `tool_call`.
/// Mirrors `codeg/src/lib/permission-request.ts`.
struct ParsedPermission {
    var title: String
    /// Human-readable description from `_meta.claudeCode.title` (claude-agent-acp
    /// ≥0.63; for Bash it is the model-authored `description` input). Preferred
    /// over ``title``, which for a shell request is the command itself — already
    /// shown verbatim in the body. `nil` when the agent supplied none.
    var description: String?
    var kind: String
    var command: String?
    var cwd: String?
    var diffFiles: [DiffFile]
    var planMarkdown: String?
    var planEntries: [PermissionPlanEntry]
    var allowedPrompts: [PermissionAllowedPrompt]
    var modeTarget: String?
    var url: String?
    var query: String?
    var prompt: String?
    var jsonPreview: String

    /// True for an ExitPlanMode / plan-bearing approval (drives plan-styled copy).
    var isPlan: Bool {
        let k = kind.lowercased().replacingOccurrences(of: "_", with: "")
        return k.contains("plan") || planMarkdown != nil || !planEntries.isEmpty
    }

    /// Whether the body has anything richer than the raw JSON fallback to show.
    var hasStructuredBody: Bool {
        command != nil || !diffFiles.isEmpty || planMarkdown != nil
            || !planEntries.isEmpty || !allowedPrompts.isEmpty
            || modeTarget != nil || url != nil || query != nil || prompt != nil
    }

    static func parse(_ toolCall: AnyJSON) -> ParsedPermission {
        let obj = toolCall.object
        let rawKind = PermissionParse.pickString(obj, ["kind", "toolName", "tool_name", "name", "type"]) ?? "tool"

        let rawInputValue = PermissionParse.pickValue(obj, ["rawInput", "raw_input", "input", "arguments", "params", "payload"])
        let rawInputObj = PermissionParse.asObject(rawInputValue)

        let command = PermissionParse.extractCommand(rawInputValue) ?? PermissionParse.extractCommand(toolCall)
        let cwd = PermissionParse.pickString(rawInputObj, ["cwd", "workdir", "workingDirectory", "working_directory"])
            ?? PermissionParse.pickString(obj, ["cwd", "workdir", "workingDirectory", "working_directory"])

        let diffText = PermissionParse.extractDiffText(rawInputValue, rawInputObj)
            ?? PermissionParse.buildDiffFromChanges(rawInputObj: rawInputObj, toolCallObj: obj)
        let diffFiles = diffText.flatMap { UnifiedDiff.parse($0) } ?? []

        let planEntries = PermissionParse.parsePlanEntries(rawInputObj)
        let planMarkdown: String? = {
            if case .string(let s)? = PermissionParse.pickValue(rawInputObj, ["plan"]) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return nil
        }()

        let allowedPrompts = PermissionParse.parseAllowedPrompts(rawInputObj)
        let modeTarget = PermissionParse.pickString(rawInputObj, ["modeId", "mode_id", "targetMode", "target_mode"])
        let url = PermissionParse.pickString(rawInputObj, ["url"]) ?? PermissionParse.pickString(obj, ["url"])
        let query = PermissionParse.pickString(rawInputObj, ["query"]) ?? PermissionParse.pickString(obj, ["query"])
        let prompt = PermissionParse.pickString(rawInputObj, ["prompt"]) ?? PermissionParse.pickString(obj, ["prompt"])
        let title = PermissionParse.pickString(obj, ["title", "toolName", "tool_name", "name"])
            ?? PermissionParse.fallbackTitle(rawKind)

        // `_meta.claudeCode.title` — NOTE the underscored key: a permission
        // request forwards the RAW ACP `ToolCallUpdate` serialization, where
        // serde renames `meta` → `_meta`. (Tool-call events carry a plain `meta`
        // instead, which is why this spelling appears nowhere else.)
        let claudeMeta = PermissionParse.asObject(
            PermissionParse.pickValue(PermissionParse.asObject(PermissionParse.pickValue(obj, ["_meta"])),
                                      ["claudeCode"]))
        let description = PermissionParse.pickString(claudeMeta, ["title"])

        return ParsedPermission(
            title: title, description: description,
            kind: rawKind, command: command, cwd: cwd, diffFiles: diffFiles,
            planMarkdown: planMarkdown, planEntries: planEntries, allowedPrompts: allowedPrompts,
            modeTarget: modeTarget, url: url, query: query, prompt: prompt,
            jsonPreview: toolCall.prettyPrinted
        )
    }
}

/// Pure parsing helpers, isolated so `ParsedPermission.parse` reads as a recipe.
private enum PermissionParse {

    static func asObject(_ v: AnyJSON?) -> [String: AnyJSON]? {
        guard let v else { return nil }
        if case .object(let o) = v { return o }
        if case .string(let s) = v {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{") else { return nil }
            return AnyJSON.parse(jsonString: t)?.object
        }
        return nil
    }

    static func pickValue(_ obj: [String: AnyJSON]?, _ keys: [String]) -> AnyJSON? {
        guard let obj else { return nil }
        for k in keys { if let v = obj[k], !v.isNull { return v } }
        return nil
    }

    static func pickString(_ obj: [String: AnyJSON]?, _ keys: [String]) -> String? {
        guard let obj else { return nil }
        for k in keys { if let s = obj[k]?.nonEmptyString { return s } }
        return nil
    }

    // MARK: Option grants (`_meta.permission`)

    /// Most change descriptions rendered for one option, and the per-description
    /// character cap. The list is agent-authored and rides both the broadcast
    /// event and the snapshot, so a bound keeps a pathological — or simply very
    /// broad — grant from turning the card into a wall of text. Anything past the
    /// cap is dropped rather than summarized: the option's own name still states
    /// what it does.
    static let maxPermissionChanges = 6
    static let maxPermissionChangeChars = 200

    /// Parse `_meta.permission = {version: 1, changes: [...]}`.
    ///
    /// Only `version: 1` is read — a future revision may reshape `changes`, and
    /// showing it half-understood is worse than showing nothing.
    ///
    /// `lifetime` is read because `description` alone does NOT always answer "for
    /// how long": codex writes the duration into its sentences, claude does not —
    /// it reports `{scope: "session"}` vs `{scope: "persistent", storage:
    /// "project"}` structurally instead. Left unread, claude's most common card
    /// would pair an "Always Allow" button with "Allow all Bash calls" and never
    /// reveal that the grant expires with the session — or, worse, that it is
    /// about to be written into settings the repo commits. The remaining
    /// structural fields (`targets`, `ruleBehavior`) stay ignored: those
    /// `description` really does summarize.
    static func optionChanges(_ meta: AnyJSON?) -> [PermissionOptionChange] {
        guard let permission = asObject(pickValue(meta?.object, ["permission"])),
              permission["version"]?.double == 1,
              let changes = pickValue(permission, ["changes"])?.array
        else { return [] }
        var out: [PermissionOptionChange] = []
        for change in changes {
            if out.count >= maxPermissionChanges { break }
            guard let description = pickString(asObject(change), ["description"]) else { continue }
            out.append(PermissionOptionChange(
                description: String(collapseWhitespace(description).prefix(maxPermissionChangeChars)),
                scope: changeScope(pickValue(asObject(change), ["lifetime"]))
            ))
        }
        return out
    }

    /// Flatten every run of whitespace to a single space.
    ///
    /// The web renders these descriptions as plain HTML, where newlines collapse
    /// to spaces — `Text` instead honors every one of them, so a description
    /// carrying a hundred newlines inside the 200-character budget would grow the
    /// card without bound and push the buttons the user is about to press off
    /// screen. Collapsing first also means the budget buys visible characters.
    ///
    /// (The cap counts Characters where the web's `slice` counts UTF-16 units, so
    /// an all-emoji description keeps twice as much here. Deliberate: capping by
    /// grapheme is the correct unit for a rendered length, and the surrounding
    /// layout is bounded independently.)
    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Wire `lifetime` → ``PermissionChangeScope``; see that type's doc.
    private static func changeScope(_ lifetime: AnyJSON?) -> PermissionChangeScope? {
        let record = asObject(lifetime)
        switch pickString(record, ["scope"]) {
        case "session": return .session
        case "process": return .process
        case "persistent": break
        default: return nil
        }
        switch pickString(record, ["storage"]) {
        case "user": return .user
        case "project": return .project
        case "project_local": return .projectLocal
        default: return .persistent
        }
    }

    static func fallbackTitle(_ kind: String) -> String {
        let normalized = kind.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return "Permission Request" }
        return normalized.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Command

    static func extractCommand(_ value: AnyJSON?, depth: Int = 0) -> String? {
        guard depth <= 4, let value, !value.isNull else { return nil }
        switch value {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || UnifiedDiff.looksLikeDiff(t) { return nil }
            if !t.hasPrefix("{"), !t.hasPrefix("[") { return t }
            return extractCommand(AnyJSON.parse(jsonString: t), depth: depth + 1)
        case .array(let arr):
            let parts = arr.compactMap { $0.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? nil : joined
        case .object(let obj):
            for key in ["command", "cmd", "script", "args", "argv", "command_args", "commandArgs"] {
                if let direct = extractCommand(obj[key], depth: depth + 1) { return direct }
            }
            for key in ["rawInput", "raw_input", "input", "arguments", "params", "payload"] {
                if let nested = extractCommand(obj[key], depth: depth + 1) { return nested }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: Diff

    static func extractDiffText(_ rawInput: AnyJSON?, _ rawInputObj: [String: AnyJSON]?) -> String? {
        var candidates: [AnyJSON?] = [rawInput]
        if let o = rawInputObj {
            candidates.append(contentsOf: [o["patch"], o["diff"], o["unified_diff"], o["unifiedDiff"]])
        }
        for c in candidates {
            guard case .string(let s)? = c else { continue }
            let normalized = unescape(s).trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, UnifiedDiff.looksLikeDiff(normalized) { return normalized }
        }
        return nil
    }

    /// Synthesize a compact unified diff from Edit-style `old_string`/`new_string`
    /// (+ file_path) or `content[]` `{type:"diff"}` entries. Returns nil if there's
    /// nothing diff-able.
    static func buildDiffFromChanges(rawInputObj: [String: AnyJSON]?, toolCallObj: [String: AnyJSON]?) -> String? {
        var blocks: [String] = []

        // Edit/Write style: a single file_path + old/new strings.
        if let o = rawInputObj,
           let path = pickString(o, ["file_path", "filePath", "path", "notebook_path", "notebookPath", "target_file", "targetFile"]) {
            let oldText = pickString(o, ["old_string", "oldString", "old_text", "oldText"]) ?? ""
            let newText = pickString(o, ["new_string", "newString", "new_text", "newText", "content", "text", "new_source", "newSource"]) ?? ""
            if let block = compactDiff(path: path, oldText: oldText, newText: newText) {
                blocks.append(block)
            }
        }

        // content[] diff items: {type:"diff", path, old_text, new_text}.
        if let content = toolCallObj?["content"]?.array {
            for item in content {
                guard let rec = item.object,
                      rec["type"]?.string?.lowercased() == "diff",
                      let path = rec["path"]?.nonEmptyString else { continue }
                let oldText = (rec["old_text"] ?? rec["oldText"])?.string ?? ""
                let newText = (rec["new_text"] ?? rec["newText"])?.string ?? ""
                if let block = compactDiff(path: path, oldText: oldText, newText: newText) {
                    blocks.append(block)
                }
            }
        }

        let joined = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Port of `buildCompactDiffFromTexts` — a minimal unified diff with 2 lines of
    /// context, trimming the common prefix/suffix.
    private static func compactDiff(path: String, oldText: String, newText: String, context: Int = 2) -> String? {
        // Drop a single trailing empty line (mirrors the web `splitNormalizedLines`)
        // so a value ending in "\n" doesn't render a spurious blank diff row.
        var oldLines = oldText.components(separatedBy: "\n")
        if oldLines.last == "" { oldLines.removeLast() }
        var newLines = newText.components(separatedBy: "\n")
        if newLines.last == "" { newLines.removeLast() }

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }

        let removed = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let added = Array(newLines[prefix..<(newLines.count - suffix)])
        if removed.isEmpty, added.isEmpty { return nil }

        let before = Array(oldLines[max(0, prefix - context)..<prefix])
        let after = Array(oldLines[(oldLines.count - suffix)..<min(oldLines.count, oldLines.count - suffix + context)])

        let oldStart = max(1, prefix + 1 - before.count)
        let oldCount = before.count + removed.count + after.count
        let newCount = before.count + added.count + after.count

        var parts = ["--- \(path)", "+++ \(path)", "@@ -\(oldStart),\(oldCount) +\(oldStart),\(newCount) @@"]
        parts.append(contentsOf: before.map { " \($0)" })
        parts.append(contentsOf: removed.map { "-\($0)" })
        parts.append(contentsOf: added.map { "+\($0)" })
        parts.append(contentsOf: after.map { " \($0)" })
        return parts.joined(separator: "\n")
    }

    // MARK: Plan / allowed prompts

    static func parsePlanEntries(_ rawInputObj: [String: AnyJSON]?) -> [PermissionPlanEntry] {
        guard let o = rawInputObj else { return [] }
        for key in ["plan", "entries", "steps", "todos"] {
            guard let list = o[key]?.array, !list.isEmpty else { continue }
            let entries: [PermissionPlanEntry] = list.compactMap { item in
                guard let rec = item.object,
                      let text = pickString(rec, ["step", "content", "title", "task", "description"]) else { return nil }
                return PermissionPlanEntry(text: text, status: pickString(rec, ["status", "state"]))
            }
            if !entries.isEmpty { return entries }
        }
        return []
    }

    static func parseAllowedPrompts(_ rawInputObj: [String: AnyJSON]?) -> [PermissionAllowedPrompt] {
        guard let list = pickValue(rawInputObj, ["allowedPrompts", "allowed_prompts"])?.array else { return [] }
        return list.compactMap { item in
            guard let rec = item.object,
                  let prompt = pickString(rec, ["prompt", "description", "text"]) else { return nil }
            return PermissionAllowedPrompt(prompt: prompt, tool: pickString(rec, ["tool", "toolName", "tool_name"]) ?? "")
        }
    }

    // MARK: Util

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
}
