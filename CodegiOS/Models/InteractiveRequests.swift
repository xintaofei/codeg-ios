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
    /// The request's tool call with whatever the live call has lent it so far —
    /// kept so a call that arrives AFTER the request can still fill it in.
    let toolCall: AnyJSON
    let parsed: ParsedPermission
    let options: [PermissionOption]
    /// Requests waiting behind this card (`queued`, then
    /// `permission_queue_depth`). One card shows at a time, so without the
    /// count the rest read as the agent having stopped.
    var queued: Int
    var id: String { requestId }

    /// The tool call this request is about, when it names one.
    var toolCallId: String? { PermissionLiveMerge.toolCallId(toolCall) }

    /// `liveInfo` is the live tool call this request is about, when the turn has
    /// one — see ``PermissionLiveMerge`` for what it may lend the request.
    init(requestId: String, toolCall: AnyJSON, options: [PermissionOption], queued: Int = 0,
         liveInfo: PermissionLiveInfo? = nil) {
        let merged = PermissionLiveMerge.merge(toolCall, with: liveInfo)
        self.requestId = requestId
        self.toolCall = merged
        self.parsed = ParsedPermission.parse(merged)
        self.options = options
        self.queued = queued
    }

    /// This request re-merged with the live call it names, after a `tool_call` /
    /// `tool_call_update` for `toolCallId` (web `mergePendingPermissionWithLiveInfo`,
    /// run from both reducers). A request can reach the client before the call
    /// it is about — Claude Code's sandbox network ask does, and only the call
    /// names the tool. Nil when the update is about another call or lends
    /// nothing new, so the caller leaves the showing card alone.
    @MainActor
    func refreshed(by live: LiveTurn, toolCallId: String) -> PendingPermission? {
        guard PermissionLiveMerge.toolCallId(toolCall) == toolCallId,
              let info = live.permissionLiveInfo(for: toolCall)
        else { return nil }
        let next = PendingPermission(requestId: requestId, toolCall: toolCall, options: options,
                                     queued: queued, liveInfo: info)
        return next.toolCall == toolCall ? nil : next
    }
}

/// What the live tool call a permission request is about knows — the input of
/// ``PermissionLiveMerge``. Plain values, so the merge stays a pure function.
struct PermissionLiveInfo: Sendable {
    let toolCallId: String
    let title: String
    let kind: String
    /// The live call's input as the wire's JSON string.
    let rawInput: String?
    /// The live call's ACP `meta`.
    let meta: AnyJSON?
}

/// Port of the web's `mergePermissionToolCallWithLiveInfo`
/// (`acp-connections-context.tsx`): fill what a permission request left out from
/// the live tool call it is about. The request stays the authority on WHAT is
/// being approved — only gaps are filled, never a field the request set.
enum PermissionLiveMerge {
    /// The id a permission request names its tool call by (web
    /// `extractPermissionToolCallId`). Probes both casings: the shared decoder
    /// camelCases `tool_call_id` / `call_id`.
    static func toolCallId(_ toolCall: AnyJSON) -> String? {
        guard let record = toolCall.object else { return nil }
        for key in ["call_id", "callId", "tool_call_id", "toolCallId", "id"] {
            if case .string(let s)? = record[key],
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    static func merge(_ toolCall: AnyJSON, with live: PermissionLiveInfo?) -> AnyJSON {
        guard let live else { return toolCall }
        let liveRawInput = live.rawInput.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        guard var next = toolCall.object else {
            guard let liveRawInput else { return toolCall }
            return .object([
                "toolCallId": .string(live.toolCallId), "title": .string(live.title),
                "kind": .string(live.kind), "rawInput": .string(liveRawInput),
            ])
        }

        if let (key, requestInput) = pickInput(next) {
            if let filled = fillStrippedEditInput(requestInput, liveRawInput: liveRawInput) {
                next[key] = .object(filled)
            }
        } else if let liveRawInput {
            next["rawInput"] = .string(liveRawInput)
        }
        if next["title"]?.nonEmptyString == nil { next["title"] = .string(live.title) }
        if next["kind"]?.nonEmptyString == nil { next["kind"] = .string(live.kind) }
        if toolCallId(.object(next)) == nil { next["toolCallId"] = .string(live.toolCallId) }

        // Which tool the request is about, by Claude Code's own name. The request
        // claude-agent-acp sends names no tool — only the live call does — and
        // the card needs it to recognize a sandbox's network request
        // (`SandboxNetworkAccess {host}`), whose request is a bare host.
        if let liveToolName = live.meta?.object?["claudeCode"]?.object?["toolName"]?.nonEmptyString {
            var meta = next["_meta"]?.object ?? [:]
            var claudeCode = meta["claudeCode"]?.object ?? [:]
            if claudeCode["toolName"]?.string == nil {
                claudeCode["toolName"] = .string(liveToolName)
                meta["claudeCode"] = .object(claudeCode)
                next["_meta"] = .object(meta)
            }
        }
        return .object(next)
    }

    /// The request's input as a tool call's raw input (web
    /// `serializePermissionToolCall`): its nested input when it has one, else
    /// the request with its wrapper fields stripped. Nil when there is none.
    static func requestInput(_ toolCall: AnyJSON) -> String? {
        guard let record = toolCall.object else { return nil }
        if let (_, value) = pickInput(record) {
            if case .string(let s) = value { return s }
            if let json = compactJSON(value) { return json }
        }
        let rest = record.filter { !wrapperKeys.contains($0.key) }
        return rest.isEmpty ? nil : compactJSON(.object(rest))
    }

    /// The title a request names its call by (web `extractPermissionToolTitle`).
    static func requestTitle(_ toolCall: AnyJSON) -> String? {
        firstString(toolCall, ["title", "tool_name", "toolName", "name", "type"])
    }

    /// The kind a request names its call by (web `extractPermissionToolKind`).
    static func requestKind(_ toolCall: AnyJSON) -> String? {
        firstString(toolCall, ["kind", "tool_name", "toolName", "name", "type"])
    }

    private static func firstString(_ toolCall: AnyJSON, _ keys: [String]) -> String? {
        guard let record = toolCall.object else { return nil }
        for key in keys {
            if case .string(let s)? = record[key], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    /// Fields of the request's own wrapper, not of the tool's input — in both
    /// casings, as the shared decoder camelCases them.
    private static let wrapperKeys = Set([
        "content", "kind", "status", "title", "toolCallId", "tool_call_id", "callId", "call_id",
    ] + inputKeys)

    private static func compactJSON(_ value: AnyJSON) -> String? {
        let any = value.foundationValue
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let inputKeys = ["rawInput", "raw_input", "input", "arguments", "params", "payload"]

    /// The keys that carry an edit's text in a file tool's input, in every
    /// spelling the card reads — plus the camelCased forms the shared decoder
    /// produces (`newSource`), which the web never sees.
    private static let editTextKeys = [
        "old_string", "oldString", "old_text", "oldText",
        "new_string", "newString", "new_text", "newText",
        "content", "text", "new_source", "newSource",
        "changes", "diff", "patch", "unified_diff", "unifiedDiff",
    ]
    private static let editPathKeys = [
        "file_path", "filePath", "path", "notebook_path", "notebookPath", "target_file", "targetFile",
    ]

    /// The request's input, and the key it sits under: the first input key whose
    /// value is neither null nor a blank string (web `pickPermissionToolInput`).
    private static func pickInput(_ record: [String: AnyJSON]) -> (String, AnyJSON)? {
        for key in inputKeys {
            guard let value = record[key], !value.isNull else { continue }
            if case .string(let s) = value, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return (key, value)
        }
        return nil
    }

    /// A file-tool input with the edit text put back from the live call, or nil
    /// when nothing is missing. claude-agent-acp 0.82.0 sends an Edit/Write
    /// approval whose input is `{file_path}` alone — the text lives only in the
    /// live call — so without this the card names the file and shows no diff.
    /// Only an input with NONE of the text keys is filled, only from a live input
    /// naming the same file, and the request's own keys win.
    private static func fillStrippedEditInput(_ requestInput: AnyJSON, liveRawInput: String?) -> [String: AnyJSON]? {
        guard let request = inputRecord(requestInput),
              let live = liveRawInput.flatMap({ AnyJSON.parse(jsonString: $0)?.object })
        else { return nil }
        if editTextKeys.contains(where: { request[$0] != nil }) { return nil }
        guard editTextKeys.contains(where: { live[$0] != nil }) else { return nil }
        guard let requestPath = filePath(request), requestPath == filePath(live) else { return nil }
        return live.merging(request) { _, own in own }
    }

    private static func inputRecord(_ value: AnyJSON) -> [String: AnyJSON]? {
        if case .string(let s) = value { return AnyJSON.parse(jsonString: s)?.object }
        return value.object
    }

    private static func filePath(_ input: [String: AnyJSON]) -> String? {
        for key in editPathKeys {
            if case .string(let s)? = input[key], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
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
    /// ≥0.63; for Bash it is the model-authored `description` input), else the
    /// backend-hoisted `_meta.permission.title` (codex-acp ≥1.7.0, claude ≥0.73.0).
    /// Preferred over ``title``, which for a shell request is the command itself —
    /// already shown verbatim in the body. `nil` when the agent supplied none.
    ///
    /// A meta heading that merely restates ``command`` is replaced by the model's
    /// own label (`rawInput.description`) when there is one — see
    /// `PermissionParse.shellCommandLabel`.
    var description: String?
    /// The agent's stated REASON for asking, from a version-1
    /// `_meta.permission.description` (codex-acp ≥1.7.0, hoisted onto the tool
    /// call by the backend). Distinct from ``description``, which names the
    /// ACTION. `nil` for every agent that sends no such block.
    var reason: String?
    /// A version-1 `_meta.permission.defaultToNo` that is literally `true`
    /// (claude-agent-acp ≥0.77.0): this ask "must not be approvable by a stray
    /// keystroke", so the card hands the emphasis to the decline. False for every
    /// other shape — the absence of the flag must never read as "dangerous".
    var defaultToNo: Bool
    /// The host a Claude Code sandbox asks to let a command reach
    /// (`SandboxNetworkAccess {host}`). Read only when `_meta.claudeCode.toolName`
    /// names that tool — which the adapter leaves off the request and
    /// ``PermissionLiveMerge`` copies over from the live call; an input that
    /// merely has a `host` is someone else's. `nil` for every other request.
    var networkHost: String?
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
        networkHost != nil || command != nil || !diffFiles.isEmpty || planMarkdown != nil
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

        // NOTE the underscored key: a permission request forwards the RAW ACP
        // `ToolCallUpdate` serialization, where serde renames `meta` → `_meta`.
        // (Tool-call events carry a plain `meta` instead, which is why this
        // spelling appears nowhere else.)
        let metaObj = PermissionParse.asObject(PermissionParse.pickValue(obj, ["_meta"]))
        let claudeMeta = PermissionParse.asObject(PermissionParse.pickValue(metaObj, ["claudeCode"]))
        let permissionMeta = PermissionParse.pickValue(metaObj, ["permission"])

        // `_meta.claudeCode.title` (claude-agent-acp ≥0.63), else the hoisted
        // `_meta.permission.title` — codex-acp ≥1.7.0's fixed titles ("Run
        // command?", "Make edits?") read better than the generic `title`.
        let metaHeading = PermissionParse.pickString(claudeMeta, ["title"])
            ?? PermissionParse.pickString(PermissionParse.asObject(permissionMeta), ["title"])

        // …unless that heading IS the command the body already shows:
        // claude-agent-acp 0.79.0 (#1070) made a shell approval's
        // `_meta.permission.title` the raw command. Keyed on the shape, not on an
        // adapter version. With no better label, the heading stays.
        let description: String?
        if let metaHeading, let command, metaHeading == command {
            description = PermissionParse.shellCommandLabel(rawInputObj, command: command) ?? metaHeading
        } else {
            description = metaHeading
        }

        let reason = PermissionParse.permissionMetaDescription(permissionMeta)
        let defaultToNo = PermissionParse.permissionMetaFlag(permissionMeta, "defaultToNo")
        let networkHost = PermissionParse.pickString(claudeMeta, ["toolName"]) == PermissionParse.sandboxNetworkTool
            ? PermissionParse.pickString(rawInputObj, ["host"])
            : nil

        return ParsedPermission(
            title: title, description: description,
            reason: reason, defaultToNo: defaultToNo, networkHost: networkHost,
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

    /// Parse an option's `_meta.permission`. Two shapes, both `version: 1`:
    ///
    /// - `{version: 1, changes: [...]}` — claude-agent-acp 0.64.1–0.72.0 and
    ///   codex-acp 1.1.8–1.6.2. Every change carries a rendered sentence.
    /// - `{version: 1, description}` — codex-acp ≥1.7.0, which dropped
    ///   `changes[]` and sends this only on MCP elicitation approvals. Read as a
    ///   single scope-less change (it carries no lifetime); `changes[]` wins
    ///   when both are present.
    ///
    /// Only `version: 1` is read — a future revision may reshape the block, and
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
              permission["version"]?.double == 1
        else { return [] }
        guard let changes = pickValue(permission, ["changes"])?.array else {
            guard let description = permissionMetaDescription(.object(permission)) else { return [] }
            return [PermissionOptionChange(description: description, scope: nil)]
        }
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

    // MARK: Request-level `_meta.permission`

    /// Claude Code's name for a sandbox's network request (see
    /// ``ParsedPermission/networkHost``).
    static let sandboxNetworkTool = "SandboxNetworkAccess"

    /// Longest agent-authored label promoted to the heading. Keeps a pathological
    /// (unbounded on the wire) `rawInput.description` from becoming the heading;
    /// the same number as ``maxPermissionChangeChars``.
    static let maxHeadingChars = 200

    /// The plain `description` of a version-1 `_meta.permission` block, trimmed
    /// to the card's budget. Shared by the request level
    /// (``ParsedPermission/reason``) and the flat option form in
    /// ``optionChanges(_:)``.
    static func permissionMetaDescription(_ permission: AnyJSON?) -> String? {
        guard let record = asObject(permission), record["version"]?.double == 1,
              let description = pickString(record, ["description"])
        else { return nil }
        return String(collapseWhitespace(description).prefix(maxPermissionChangeChars))
    }

    /// A boolean flag of the same version-1 block. Only a real `true` counts: the
    /// flag gates a SAFER presentation, so an unrecognized shape (`"true"`, `1`,
    /// a later version) falls back to the ordinary card.
    static func permissionMetaFlag(_ permission: AnyJSON?, _ key: String) -> Bool {
        guard let record = asObject(permission), record["version"]?.double == 1 else { return false }
        return record[key]?.bool == true
    }

    /// The model's own one-line label for a shell command (`rawInput.description`)
    /// — what claude-agent-acp used as the approval heading through 0.78.0.
    /// `nil` when missing or merely restating the command, so the caller keeps
    /// the heading it already had.
    static func shellCommandLabel(_ rawInputObj: [String: AnyJSON]?, command: String) -> String? {
        guard let label = pickString(rawInputObj, ["description"]), label != command else { return nil }
        return String(label.prefix(maxHeadingChars))
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

    /// The command a permission request asks to run, dug out of whatever shape
    /// the agent used. Port of the web's `extractCommandFromUnknownValue`.
    ///
    /// `verbatim` marks a string LEAF sitting directly under a key that names a
    /// command (`command`, `cmd`, `script`, `args`, …). Such a string IS the
    /// command, so the two heuristics guarding the broad walk against
    /// stringified payloads do not apply to it:
    ///
    /// - the `{` / `[` envelope prefix — plenty of shell opens with one
    ///   (`[ -f x ] && …`, `{ npm test; }`, PowerShell's
    ///   `[System.Environment]::OSVersion`). Only a string that FAILS to parse is
    ///   shell; one that parses is unwrapped as before, so a stringified argv
    ///   still joins and a parse with no command still yields nil;
    /// - the diff-payload check, which matches any command that WRITES a patch.
    ///
    /// The mark lasts ONE hop: descending from a command key into an object
    /// (`{args: {payload: "{…}"}}`) drops back to the conservative reading, since
    /// `args` is a generic MCP argument bag on some agents.
    static func extractCommand(_ value: AnyJSON?, depth: Int = 0, verbatim: Bool = false) -> String? {
        guard depth <= 4, let value, !value.isNull else { return nil }
        switch value {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if !t.hasPrefix("{"), !t.hasPrefix("[") {
                return !verbatim && ActivityEdit.looksLikeDiffPayload(t) ? nil : t
            }
            // A real envelope is structured data again — it re-earns the mark
            // through its own keys. Not JSON at all: shell on a command leaf, an
            // unreadable payload in the open.
            guard let parsed = AnyJSON.parse(jsonString: t) else { return verbatim ? t : nil }
            return extractCommand(parsed, depth: depth + 1)
        case .array(let arr):
            let parts = arr.compactMap { $0.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? nil : joined
        case .object(let obj):
            for key in ["command", "cmd", "script", "args", "argv", "command_args", "commandArgs"] {
                if let direct = extractCommand(obj[key], depth: depth + 1, verbatim: true) { return direct }
            }
            // Wrappers, not command fields: never carry the mark in here.
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
