import Foundation

// Pure parsing + status resolution for the delegation companion tools, ported
// from the web client's `delegation-card.ts` (delegate_to_agent) and
// `delegation-status.ts` (get_delegation_status / cancel_delegation). No UI, no
// live binding — iOS resolves everything from the tool input/output strings.
//
// ADAPTATION: `ToolCallVM` has no separate `errorText` channel — an error result
// rides in `output` with the `isError` flag set. Every web `(output, errorText)`
// entry point is reached here via `output` (= the result text) plus a `hasError`
// flag, so an error report still parses (it may be a structured failure report)
// while the badge/status reflect the failure.

// MARK: - delegate_to_agent

/// Agent / task / working dir pulled from a `delegate_to_agent` call's input.
struct DelegationParsedInput: Equatable {
    var agentType: AgentType?
    /// The assistant the call names (`assistant_id`). Parsed for parity with
    /// the web's `ParsedInput`; the iOS card has no assistant identity yet.
    var assistantId: Int?
    var task: String?
    var workingDir: String?
}

/// The parent `delegate_to_agent` output. Under async delegation the output is a
/// running *ack* (the real result arrives later via `get_delegation_status`), so
/// an ack is kept distinct from a terminal outcome — otherwise the card would
/// paint the ack as the result and flip its badge to "ok" prematurely.
///
/// `report` is the broker report the output was read from, nil when only
/// opaque result text survived (web: `errorCode` set vs left `undefined`).
enum DelegationToolOutput {
    case ack(childConversationId: Int?, report: DelegationReport)
    case outcome(text: String, isError: Bool, childConversationId: Int?, report: DelegationReport?)

    var report: DelegationReport? {
        switch self {
        case .ack(_, let report): return report
        case .outcome(_, _, _, let report): return report
        }
    }
}

/// What a recovered broker report — the async `DelegationTaskReport` or the
/// legacy synchronous `DelegationOutcome` — carries beyond its kind.
struct DelegationReport: Equatable {
    /// `error_code` (`code` on the legacy shape); nil when the report carried
    /// none. Read on EVERY variant, not just the failed ones: a refused resume
    /// pairs `not_resumable` with the task's real status, so the code is the
    /// only thing that tells it from the report of a genuine resume.
    var errorCode: String?
    /// The agent the task runs on, as the broker reports it — what a
    /// `resume_delegation` card is drawn by, its arguments naming only a task.
    var agentType: AgentType? = nil
    /// The assistant the task runs as, when it runs as one.
    var assistantName: String? = nil
}

/// The status a delegation card renders. `waiting`: the child is parked on
/// the user's decision, as a check on it reported.
enum DelegationCardStatus {
    case starting, running, waiting, ok, err
}

/// The broker-written `meta["codeg.delegation"]` on the parent `delegate_to_agent`
/// tool call. Under ASYNC delegation the tool *output* is only a running ack, so
/// the terminal result is recorded here instead (the broker patches the tool
/// call's meta to `completed` / `failed` once the child finishes) — and a
/// snapshot or DB re-fetch carries it. This is the authoritative status source,
/// so the card prefers it over the ack: without it an async delegation reads
/// "Running" forever even after it finished. Mirrors web `parseDelegationMeta`.
struct ParsedDelegationMeta {
    var status: DelegationCardStatus
    var errorCode: String?
    var childConversationId: Int?
    var textPreview: String?
    var durationMs: Double?
    /// Broker-minted task id, mirrored on every meta write — the only place a
    /// call whose result names none (an opencode code-mode script) carries it.
    var taskId: String?
    /// The child's agent. Only the HISTORICAL injection (a detail load, off
    /// the child's row) carries it — the only agent source for a reloaded
    /// `resume_delegation`, whose arguments are just `{task_id, reason}`.
    var agentType: AgentType? = nil
    /// The assistant the task ran as, by its name when it started.
    var assistantName: String? = nil
    /// The bounded task text the broker stamped — the label when the call's
    /// own arguments never carried it (Cursor) and no live binding is left.
    var task: String? = nil
}

enum DelegationModel {

    // MARK: delegate input

    /// Agent / task / working dir from a `delegate_to_agent` call's input
    /// (web `parseInput`): the JSON arguments, possibly inside a host wrapper,
    /// or — for an opencode code-mode `execute` — the JS object literal inside
    /// its `code` source, read by ``CodeModeDelegation``. A code-mode call whose
    /// arguments can't be read is still one: its fields stay nil and the card
    /// shows a generic sub-agent.
    static func parseInput(_ raw: String?) -> DelegationParsedInput {
        if let obj = CompanionDetect.unwrapArgs(CompanionJSON.object(from: raw)), hasDelegationArgs(obj) {
            return DelegationParsedInput(
                agentType: coerceAgentType(obj["agent_type"]),
                assistantId: coerceAssistantId(obj["assistant_id"]),
                task: obj["task"] as? String,
                workingDir: obj["working_dir"] as? String
            )
        }
        if let args = CodeModeDelegation.parseArgs(raw) {
            return DelegationParsedInput(
                agentType: coerceAgentType(args.agentType),
                assistantId: coerceAssistantId(args.assistantId),
                task: args.task,
                workingDir: args.workingDir
            )
        }
        return DelegationParsedInput()
    }

    /// The web `findDelegationArgs` direct hit: the object declares at least
    /// one delegation field.
    private static func hasDelegationArgs(_ obj: [String: Any]) -> Bool {
        obj["task"] is String || obj["agent_type"] is String || obj["working_dir"] is String
            || coerceAssistantId(obj["assistant_id"]) != nil
    }

    /// Every agent type codeg 0.44 knows (web `ALL_AGENT_TYPES`) — more than
    /// iOS has hand-written support for; the rest draw as `.other(wire:)`.
    private static let knownAgentTypes: Set<String> = [
        "claude_code", "codex", "open_code", "gemini", "open_claw", "cline", "hermes",
        "code_buddy", "kimi_code", "minimax_code", "pi", "grok", "cursor", "deepseek",
        "qoder", "antigravity", "kiro", "zcode", "trae", "command_code",
    ]

    /// Narrow an untrusted wire value to an agent type, or nil (web
    /// `coerceAgentType`): a known agent, or any `custom:<id>` slug. Not
    /// `AgentType(rawValue:)` alone, which never fails — an unknown slug must
    /// draw the generic sub-agent, not an agent named after it.
    static func coerceAgentType(_ value: Any?) -> AgentType? {
        guard let value = value as? String else { return nil }
        let trimmed = ToolNameNormalizer.jsTrim(value)
        guard !trimmed.isEmpty,
              knownAgentTypes.contains(trimmed) || trimmed.hasPrefix(AgentType.customWirePrefix)
        else { return nil }
        return AgentType(rawValue: trimmed)
    }

    /// Largest assistant id: the backend keeps them in a 32-bit integer.
    private static let maxAssistantId = 2_147_483_647

    /// Narrow an untrusted wire value to an assistant id, or nil (web
    /// `coerceAssistantId`): a positive integer, or a string of digits (some
    /// hosts stringify numeric arguments). Never a boolean.
    static func coerceAssistantId(_ value: Any?) -> Int? {
        let n: Double
        if let s = value as? String {
            // `/^[1-9]\d{0,9}$/` on the trimmed text (`\d` is ASCII in JS).
            let digits = Array(ToolNameNormalizer.jsTrim(s).utf16)
            guard (1...10).contains(digits.count), digits[0] != 0x30,
                  digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            n = Double(String(decoding: digits, as: UTF16.self)) ?? 0
        } else if let number = ActivityJSON.number(value) {
            n = number
        } else {
            return nil
        }
        guard n.isFinite, n == n.rounded(), n >= 1, n <= Double(maxAssistantId) else { return nil }
        return Int(n)
    }

    // MARK: delegate meta

    /// Read the broker's `meta["codeg.delegation"]` off a tool call. Returns nil
    /// when the meta is absent or carries no recognized status (caller then falls
    /// back to the ack output). Mirrors web `parseDelegationMeta`.
    ///
    /// The inner keys reach us in EITHER case: the shared event/transcript decoder
    /// runs `.convertFromSnakeCase` (→ `childConversationId`), while a meta parsed
    /// from a raw JSON string keeps snake_case (`child_conversation_id`). Probe
    /// both, per the `AnyJSON` casing convention.
    static func parseDelegationMeta(_ meta: AnyJSON?) -> ParsedDelegationMeta? {
        guard let meta else { return nil }
        let outer: [String: AnyJSON]?
        switch meta {
        case .object(let o): outer = o
        case .string(let s): outer = AnyJSON.parse(jsonString: s)?.object
        default: outer = nil
        }
        // The `codeg.delegation` key has a dot, not an underscore, so
        // `.convertFromSnakeCase` leaves it intact.
        guard let inner = outer?["codeg.delegation"]?.object else { return nil }

        guard let rawStatus = inner["status"]?.string else { return nil }
        let status: DelegationCardStatus
        switch rawStatus {
        case "running", "pending":   status = .running
        case "completed", "ok":      status = .ok
        case "failed", "err":        status = .err
        default:                     return nil
        }
        func pick(_ keys: [String]) -> AnyJSON? {
            for k in keys { if let v = inner[k], !v.isNull { return v } }
            return nil
        }
        // The task id verbatim, as the web reads it (`typeof === "string" && id`).
        let taskId = pick(["task_id", "taskId"])?.string.flatMap { $0.isEmpty ? nil : $0 }
        return ParsedDelegationMeta(
            status: status,
            errorCode: pick(["error_code", "errorCode"])?.nonEmptyString,
            childConversationId: pick(["child_conversation_id", "childConversationId"])?.double.map { Int($0) },
            textPreview: pick(["text_preview", "textPreview"])?.nonEmptyString,
            durationMs: pick(["duration_ms", "durationMs"])?.double,
            taskId: taskId,
            agentType: coerceAgentType(pick(["agent_type", "agentType"])?.string),
            assistantName: pick(["assistant_name", "assistantName"])?.string.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            },
            task: pick(["task_preview", "taskPreview"])?.nonEmptyString
        )
    }

    // MARK: delegate output

    static func parseToolOutput(_ raw: String?, forceError: Bool = false) -> DelegationToolOutput? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        var decoded: [String: Any]?
        if let any = ToolJSONFormat.parseAny(trimmed) {
            if let o = any as? [String: Any] {
                decoded = o
            } else if !(any is [Any]) {
                // Top-level primitive (string / number / bool) — render directly.
                return .outcome(text: scalarText(any), isError: forceError, childConversationId: nil, report: nil)
            }
            // An array falls through to the embedded-object scan below.
        }
        if decoded == nil { decoded = EmbeddedJSON.extractObject(trimmed) }

        guard let parsed = decoded else {
            return .outcome(text: trimmed, isError: forceError, childConversationId: nil, report: nil)
        }

        // A host envelope around the MCP result — Codex's live wire sends
        // `{result: <CallToolResult>, error: null}` — is peeled first, so the chain
        // below only ever faces the result itself.
        let peel = McpResultEnvelope.peel(parsed, isResolvable: isResolvableDelegateResult)
        let obj = peel.obj

        // MCP `CallToolResult` envelope: `{ content, structuredContent?, isError? }`.
        if let content = obj["content"] as? [Any] {
            let inner = obj["structuredContent"] as? [String: Any]
            let envIsError = (CompanionJSON.bool(obj["isError"]) == true)
            if let inner, let interpreted = interpretReport(inner) {
                return applyOuterError(interpreted, force: envIsError)
            }
            if let fromContent = interpretMcpContentArray(content) {
                return applyOuterError(fromContent, force: envIsError)
            }
            if let first = content.first as? [String: Any], let text = first["text"] as? String {
                return .outcome(text: text, isError: envIsError || forceError,
                                childConversationId: inner.flatMap(childConversationId), report: nil)
            }
        }

        if let interpreted = interpretReport(obj) {
            return applyOuterError(interpreted, force: forceError)
        }

        // A host envelope that failed outright carries no result to render — its
        // own error string is the whole story, and beats dumping the envelope JSON.
        if let hostError = peel.hostError {
            return .outcome(text: hostError, isError: true, childConversationId: nil, report: nil)
        }

        // Unrecognized JSON — pretty-print so we don't surface raw braces.
        let pretty = ToolJSONFormat.prettyPrint(obj) ?? trimmed
        return .outcome(text: "```json\n\(pretty)\n```", isError: forceError, childConversationId: nil, report: nil)
    }

    /// Whether `obj` is already one of the shapes ``parseToolOutput`` reads — a
    /// report (`status`), a legacy outcome (`kind`), or an MCP `CallToolResult`.
    /// Stops the host-envelope peel at a result that itself happens to carry a
    /// `result` key. (A child's arbitrary payload is guarded on the other side too:
    /// the peel only ever descends INTO a real `CallToolResult`.)
    static func isResolvableDelegateResult(_ obj: [String: Any]) -> Bool {
        if obj["status"] is String { return true }
        if obj["kind"] is String { return true }
        if obj["content"] is [Any] { return true }
        return obj["structuredContent"] is [String: Any]
    }

    /// Resolve the delegation card status. iOS-trimmed mirror of the web
    /// `resolveDelegationStatus` (no live binding / child-permission state):
    /// broker meta → error → running-ack → terminal outcome → done → starting.
    ///
    /// The persisted/snapshot `meta["codeg.delegation"]` is the authoritative
    /// terminal signal and wins over everything below it — under async delegation
    /// the parent output is only a running ack, so without the meta the card would
    /// read "Running" forever even after the child completed.
    static func resolveStatus(parsedMeta: ParsedDelegationMeta?, toolOutput: DelegationToolOutput?, state: ToolCallState, hasError: Bool) -> DelegationCardStatus {
        if let parsedMeta { return parsedMeta.status }
        if hasError { return .err }
        if isBareAck(toolOutput) { return .running }
        switch toolOutput {
        case .ack: return .running
        case .outcome(_, let isError, _, _): return isError ? .err : .ok
        case nil: return state == .done ? .ok : .starting
        }
    }

    /// The broker-minted `task_id` from the ack, so a delegate card can correlate
    /// with the later status / cancel cards. Carried as `structuredContent.task_id`
    /// (persisted) or embedded in the ack text as `task_id=<id>` (live wire).
    static func parseDelegateTaskId(output: String?, errorText: String?) -> String? {
        for raw in [output, errorText] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let obj = ToolJSONFormat.parseObject(trimmed) ?? EmbeddedJSON.extractObject(trimmed) {
                // Peel Codex's live `{result, error}` wrapper so `structuredContent`
                // is reachable; a bare `task_id` at this level already ends the walk.
                let result = McpResultEnvelope.peel(obj) {
                    $0["task_id"] is String || isResolvableDelegateResult($0)
                }.obj
                if let sc = result["structuredContent"] as? [String: Any], let id = sc["task_id"] as? String, !id.isEmpty {
                    return id
                }
                if let id = result["task_id"] as? String, !id.isEmpty { return id }
            }
            if let m = Rx.capture(trimmed, #"task_id[=:]\s*"?([A-Za-z0-9][\w-]*)"?"#, groups: 1), !m[0].isEmpty {
                return m[0]
            }
        }
        return nil
    }

    /// The broker task id a `delegate_to_agent` call was given, from what the
    /// call itself carries: its ack, else the meta the broker stamped on it
    /// (web `delegateCallTaskId`). An opencode code-mode script's result is
    /// whatever the script returned, so there the meta is often the only
    /// source.
    static func delegateCallTaskId(_ vm: ToolCallVM) -> String? {
        let pair = outputError(vm)
        return parseDelegateTaskId(output: pair.output, errorText: pair.errorText)
            ?? parseDelegationMeta(vm.meta)?.taskId
    }

    // MARK: resume_delegation verdicts

    /// `DelegationTaskReport.error_code` for a refused `resume_delegation`
    /// (`broker.rs::NOT_RESUMABLE_CODE`).
    static let notResumableCode = "not_resumable"

    /// Opening words of the broker's refusal message, which must stay readable
    /// when the structured report is gone: `render_task_report` renders only
    /// `message` as content text, and some hosts (OpenCode) drop
    /// `structuredContent` entirely. The backend writes this prefix
    /// deliberately for that case (`broker.rs::not_resumable_report`).
    static let refusedResumeText = "Not resumed:"

    /// Whether a `resume_delegation` result is the broker REFUSING to resume
    /// (web `isRefusedResume`).
    ///
    /// This cannot be read off `status`: a refusal reports the task's ACTUAL
    /// state, so "already completed" arrives as `completed` and "still
    /// running" as `running` — indistinguishable from a real resume by status
    /// alone. Only `error_code` separates them, or, where no structure
    /// survived, the message prefix. It matters because a refusal still
    /// carries `agent_type` and `child_conversation_id`, the evidence a resumed
    /// sub-agent runs on: without this check a resume that never happened
    /// claims the task's later checks and stays in view as if it were running.
    static func isRefusedResume(output: String?, errorText: String?) -> Bool {
        let parsed = parseResumeResult(output: output, errorText: errorText)
        // Structure survived ⇒ it is the whole answer. Falling through to the
        // text would be reading a child's own output for a verdict on the call.
        if let report = parsed?.report { return report.errorCode == notResumableCode }
        return opensWith(parsed, output, refusedResumeText) || opensWith(parsed, errorText, refusedResumeText)
    }

    /// ``isRefusedResume(output:errorText:)`` on a call (iOS keeps an error
    /// result in `output`; see ``outputError(_:)``).
    static func isRefusedResume(_ vm: ToolCallVM) -> Bool {
        let pair = outputError(vm)
        return isRefusedResume(output: pair.output, errorText: pair.errorText)
    }

    private static func parseResumeResult(output: String?, errorText: String?) -> DelegationToolOutput? {
        (errorText?.isEmpty == false ? parseToolOutput(errorText, forceError: true) : nil) ?? parseToolOutput(output)
    }

    /// Does this result OPEN with the marker? Anchored, never a substring
    /// search: for a `completed` report the content text is the child's own
    /// LLM-written output, and a sub-agent that merely discusses delegation
    /// must not be read as a verdict on its card. Checks the parsed outcome
    /// text as well as the raw string, so a host envelope around the message
    /// doesn't hide it. (JS `trimStart().startsWith`: code units.)
    private static func opensWith(_ parsed: DelegationToolOutput?, _ raw: String?, _ marker: String) -> Bool {
        var parsedText: String?
        if case .outcome(let text, _, _, _)? = parsed { parsedText = text }
        return [parsedText, raw].contains { candidate in
            guard let candidate else { return false }
            return ToolNameNormalizer.jsTrimStart(candidate).utf16.starts(with: marker.utf16)
        }
    }

    private static func applyOuterError(_ output: DelegationToolOutput, force: Bool) -> DelegationToolOutput {
        guard force, case .outcome(let text, _, let cid, let report) = output else { return output }
        return .outcome(text: text, isError: true, childConversationId: cid, report: report)
    }

    /// The broker's async `DelegationTaskReport` (by `status`) or the legacy
    /// synchronous `DelegationOutcome` (by `kind`). nil when neither discriminator
    /// is present.
    private static func interpretReport(_ obj: [String: Any]) -> DelegationToolOutput? {
        let cid = childConversationId(obj)
        // Carried on EVERY variant — see `DelegationReport.errorCode`.
        let report = DelegationReport(errorCode: obj["error_code"] as? String,
                                      agentType: coerceAgentType(obj["agent_type"]),
                                      assistantName: assistantName(obj["assistant_name"]))
        if let status = obj["status"] as? String {
            switch status {
            case "running", "unknown":
                return .ack(childConversationId: cid, report: report)
            case "completed":
                return .outcome(text: (obj["text"] as? String) ?? "", isError: false,
                                childConversationId: cid, report: report)
            case "failed", "canceled":
                return .outcome(text: failureText(message: obj["message"], code: obj["error_code"]),
                                isError: true, childConversationId: cid, report: report)
            default:
                return .ack(childConversationId: cid, report: report)
            }
        }
        // The legacy synchronous outcome. Its report is set too — nil code
        // where there is none — because its ABSENCE is what reads as "no report
        // survived, fall back to the text": a well-formed legacy result whose
        // text merely opens with "Not resumed:" must not be taken for a refusal.
        if let kind = obj["kind"] as? String {
            if kind == "ok" {
                return .outcome(text: (obj["text"] as? String) ?? "", isError: false,
                                childConversationId: cid, report: DelegationReport(errorCode: nil))
            }
            if kind == "err" {
                // The legacy shape spells the code `code`, not `error_code`.
                let code = (obj["code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .outcome(text: failureText(message: obj["message"], code: obj["code"]),
                                isError: true, childConversationId: cid, report: DelegationReport(errorCode: code))
            }
        }
        return nil
    }

    /// A report inlined in `content[0]` when the host surfaced no usable
    /// `structuredContent` — either a structured `.json` field or (Codex-style) a
    /// JSON string in `.text`.
    private static func interpretMcpContentArray(_ content: [Any]) -> DelegationToolOutput? {
        guard let first = content.first as? [String: Any] else { return nil }
        if let json = first["json"] as? [String: Any], let interpreted = interpretReport(json) {
            return interpreted
        }
        if let text = first["text"] as? String, let embedded = EmbeddedJSON.extractObject(text),
           let interpreted = interpretReport(embedded) {
            return interpreted
        }
        return nil
    }

    private static func failureText(message: Any?, code: Any?) -> String {
        if let m = message as? String, !m.isEmpty { return m }
        if let c = code as? String, !c.isEmpty { return c }
        return "Delegation failed."
    }

    private static func childConversationId(_ obj: [String: Any]) -> Int? {
        guard let n = obj["child_conversation_id"] as? NSNumber, !ToolJSONFormat.isBoolean(n) else { return nil }
        return n.intValue
    }

    /// A non-empty assistant name off the wire, as sent (web `coerceAssistantName`).
    static func assistantName(_ value: Any?) -> String? {
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func scalarText(_ value: Any) -> String {
        if let s = value as? String { return s }
        if ToolJSONFormat.isBoolean(value), let n = value as? NSNumber { return n.boolValue ? "true" : "false" }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value)
    }
}

// MARK: - get_delegation_status / cancel_delegation

/// Which companion tool a status row represents — selects label + icon, and
/// flips the meaning of a `canceled` task (success for cancel, error for status).
enum DelegationRowKind { case status, cancel }

enum TaskStatus: String { case running, completed, failed, canceled, unknown }

/// Visual badge state. `checked` is the neutral, non-spinning state for a poll
/// that RETURNED while the task was still running (a settled snapshot, not live
/// work) — so a superseded check stops spinning.
enum BadgeStatus { case starting, running, waiting, ok, err, checked }

struct ResolvedBadge {
    let status: BadgeStatus
    var errorCode: String?
}

/// One task's resolved status report (the structured `DelegationTaskReport` when
/// recoverable, else best-effort from the result text + tool state).
struct StatusReport {
    var status: TaskStatus?
    var taskId: String?
    var text: String?
    var errorCode: String?
    var durationMs: Double?
    /// A running report whose sub-agent is parked on the user's decision
    /// (Rust `blocked_on`, or the backend's blocked note on a text-only host).
    var blocked = false
    /// How far the sub-agent had got (Rust `DelegationTaskReport.progress`).
    var progress: DelegationProgress? = nil
    var agentType: AgentType? = nil
    var childConversationId: Int? = nil
}

/// A sub-agent's step count and what it is doing now (web `StepProgress`,
/// without the per-step marks this client doesn't draw).
struct DelegationProgress: Equatable {
    let steps: Int
    let lastStep: String?
}

/// One row of the status card: a task ref, its latest poll's report + badge, and
/// one result entry per poll that touched it (the `×N` hint + the expand pager).
struct DelegationTaskRow: Identifiable {
    let key: String
    let taskId: String?
    let report: StatusReport
    let badge: ResolvedBadge
    let results: [String?]
    var id: String { key }
}

extension DelegationModel {

    // MARK: status parsing

    /// Map a VM to the web `(output, errorText)` pair: an errored result's text
    /// lives in `output`, surfaced through the `errorText` slot so resolution
    /// treats it as an error while still parsing any structured failure report.
    static func outputError(_ vm: ToolCallVM) -> (output: String?, errorText: String?) {
        vm.isError ? (nil, vm.output) : (vm.output, nil)
    }

    static func parseStatusReport(output: String?, errorText: String?) -> StatusReport {
        let raw = (output ?? errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return StatusReport() }

        let (parsed, hostError) = parseResultObject(raw)
        guard let obj = parsed else {
            return StatusReport(status: textRunningStatus(raw), text: raw, blocked: textIsBlocked(raw))
        }
        let contentText = firstContentText(obj)
        let sc = obj["structuredContent"] as? [String: Any]
        var report: [String: Any]?
        var displayText: String? = contentText
        if isReport(sc, trusted: true) {
            report = sc
        } else if isReport(obj, trusted: false) {
            report = obj
        } else if let contentText, let embedded = EmbeddedJSON.extractObject(contentText), isReport(embedded, trusted: false) {
            report = embedded
            displayText = nil   // content[0].text WAS the report JSON, not a message
        }
        if let report {
            let text = displayText ?? str(report, "text") ?? str(report, "message")
            return reportFromObject(report, text: text,
                                    blockedText: text ?? str(report, "message") ?? contentText)
        }
        // A host envelope that failed outright carries no result to show, so its own
        // error string beats dumping the envelope JSON.
        let fallbackText = contentText ?? hostError ?? raw
        return StatusReport(status: textRunningStatus(fallbackText), text: fallbackText,
                            blocked: textIsBlocked(fallbackText))
    }

    /// One report per task. A batch poll returns `{ "tasks": [report, ...] }`
    /// (in `structuredContent`, top-level, or embedded in `content[0].text`);
    /// otherwise this is the single-report path.
    static func parseStatusReports(output: String?, errorText: String?) -> [StatusReport] {
        let raw = (output ?? errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let obj = parseResultObject(raw).obj, let found = findTasksArray(obj),
           !found.tasks.isEmpty, found.tasks.contains(where: { isReport($0 as? [String: Any], trusted: found.trusted) }) {
            return found.tasks.map { reportFromObject(($0 as? [String: Any]) ?? [:]) }
        }
        return [parseStatusReport(output: output, errorText: errorText)]
    }

    /// The task id(s) a poll was called with — `{ task_ids: [...] }` or a legacy
    /// `{ task_id }` — peeling host wrappers / double-encoded JSON. Ordered, deduped.
    static func parseTaskIds(_ raw: String?) -> [String] {
        findTaskIds(CompanionJSON.object(from: raw))
    }

    /// Resolve the status badge: the structured `status` wins; else fall back to
    /// the tool-call lifecycle. A RETURNED `running` report resolves to `checked`
    /// (neutral) — the live spinner is only for a poll still in flight.
    static func deriveBadge(kind: DelegationRowKind, report: StatusReport, state: ToolCallState, hasError: Bool) -> ResolvedBadge {
        switch report.status {
        case .completed: return ResolvedBadge(status: .ok)
        // Parked on the user, it waits; otherwise it came back still working.
        case .running:   return ResolvedBadge(status: report.blocked ? .waiting : .checked)
        case .unknown:   return ResolvedBadge(status: .err, errorCode: "unknown")
        case .failed:    return ResolvedBadge(status: .err, errorCode: report.errorCode)
        case .canceled:
            return kind == .cancel
                ? ResolvedBadge(status: .ok)
                : ResolvedBadge(status: .err, errorCode: report.errorCode ?? "canceled")
        case nil: break
        }
        if hasError { return ResolvedBadge(status: .err) }
        if state == .done { return ResolvedBadge(status: .ok) }
        if state == .running || state == .inputStreaming { return ResolvedBadge(status: .running) }
        return ResolvedBadge(status: .starting)
    }

    /// Compact human duration: `350ms`, `1.2s`, `12s`, `2m 0s`.
    static func formatDuration(_ ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms.rounded()))ms" }
        if ms < 10_000 { return String(format: "%.1fs", ms / 1000) }
        let totalSec = Int((ms / 1000).rounded())
        if totalSec < 60 { return "\(totalSec)s" }
        return "\(totalSec / 60)m \(totalSec % 60)s"
    }

    /// Group a run of status polls into one row per task — a task polled N times
    /// shows `×N` with its latest outcome; parallel waits surface as one row each.
    static func buildTaskRows(_ polls: [ToolCallVM], kind: DelegationRowKind = .status) -> [DelegationTaskRow] {
        var order: [String] = []
        var byKey: [String: (taskId: String?, polls: [(vm: ToolCallVM, report: StatusReport)])] = [:]
        for poll in polls {
            let (out, err) = outputError(poll)
            let reports = parseStatusReports(output: out, errorText: err)
            let inputIds = parseTaskIds(poll.input)
            let count = max(reports.count, inputIds.count, 1)
            for i in 0..<count {
                let report = i < reports.count ? reports[i] : StatusReport()
                let taskId = report.taskId ?? (i < inputIds.count ? inputIds[i] : nil)
                let key = taskId ?? "__unattributed__:\(poll.id):\(i)"
                if byKey[key] == nil { byKey[key] = (taskId, []); order.append(key) }
                byKey[key]?.polls.append((poll, report))
            }
        }
        return order.map { key in
            let entry = byKey[key]!
            let latest = entry.polls[entry.polls.count - 1]
            let (_, latestErr) = outputError(latest.vm)
            let badge = deriveBadge(kind: kind, report: latest.report, state: latest.vm.state,
                                    hasError: latestErr != nil || latest.vm.isError)
            return DelegationTaskRow(key: key, taskId: entry.taskId, report: latest.report,
                                     badge: badge, results: entry.polls.map { $0.report.text })
        }
    }

    // MARK: status helpers

    private static func str(_ obj: [String: Any], _ key: String) -> String? {
        if let s = obj[key] as? String, !s.isEmpty { return s }
        return nil
    }
    private static func num(_ obj: [String: Any], _ key: String) -> Double? {
        guard let n = obj[key] as? NSNumber, !ToolJSONFormat.isBoolean(n) else { return nil }
        return n.doubleValue
    }
    private static func firstContentText(_ envelope: [String: Any]) -> String? {
        guard let content = envelope["content"] as? [Any], let first = content.first as? [String: Any] else { return nil }
        return str(first, "text")
    }
    private static func validStatus(_ obj: [String: Any]?) -> TaskStatus? {
        guard let s = obj?["status"] as? String else { return nil }
        return TaskStatus(rawValue: s)
    }

    /// `structuredContent` is trusted; an untrusted source (raw text /
    /// `content[0].text`, which on the live wire is the child's own output) must
    /// ALSO carry the report's `task_id`, so a child whose output is JSON-with-status
    /// isn't misread as a report.
    private static func isReport(_ obj: [String: Any]?, trusted: Bool) -> Bool {
        guard let obj, validStatus(obj) != nil else { return false }
        if trusted { return true }
        if let id = obj["task_id"] as? String, !id.isEmpty { return true }
        return false
    }

    /// Parse a result string into its envelope/report object, peeling one layer of
    /// double-encoding (JSON-of-JSON). An array / number yields nil (matches web).
    ///
    /// The parsed object is then stripped of any host envelope around the MCP
    /// result: codex's LIVE wire hands us `{result: <CallToolResult>, error: null}`,
    /// which otherwise resolves to no report at all and paints the raw envelope JSON
    /// into the card. (Codex's PERSISTED rollout carries the bare
    /// `Wall time:…\nOutput:\n<json>` instead, which already parsed — so only the
    /// live path was affected.)
    private static func parseResultObject(_ raw: String) -> (obj: [String: Any]?, hostError: String?) {
        func peeled(_ obj: [String: Any]?) -> (obj: [String: Any]?, hostError: String?) {
            guard let obj else { return (nil, nil) }
            let result = McpResultEnvelope.peel(obj, isResolvable: isResolvableStatusResult)
            return (result.obj, result.hostError)
        }
        guard let any = ToolJSONFormat.parseAny(raw) else { return peeled(EmbeddedJSON.extractObject(raw)) }
        if let o = any as? [String: Any] { return peeled(o) }
        if let s = any as? String { return peeled(ToolJSONFormat.parseObject(s) ?? EmbeddedJSON.extractObject(s)) }
        return (nil, nil)
    }

    /// Whether `obj` is already one of the shapes the status resolution reads — a
    /// report, a batch, or an MCP content envelope. Stops the host-envelope peel at
    /// a result that itself happens to carry a `result` key.
    private static func isResolvableStatusResult(_ obj: [String: Any]) -> Bool {
        if validStatus(obj) != nil { return true }
        if obj["tasks"] is [Any] { return true }
        if obj["content"] is [Any] { return true }
        return obj["structuredContent"] is [String: Any]
    }

    private static func reportFromObject(_ report: [String: Any], text: String? = nil,
                                         blockedText: String? = nil) -> StatusReport {
        let text = text ?? str(report, "text") ?? str(report, "message")
        return StatusReport(
            status: validStatus(report),
            taskId: str(report, "task_id"),
            text: text,
            errorCode: str(report, "error_code"),
            durationMs: num(report, "duration_ms"),
            // Structured `blocked_on` when the host kept it; otherwise the
            // blocked note in the message, all a content-only host leaves.
            blocked: report["blocked_on"] is [String: Any] || textIsBlocked(blockedText ?? text),
            progress: progress(report["progress"]),
            agentType: coerceAgentType(report["agent_type"]),
            childConversationId: childConversationIdOf(report)
        )
    }

    /// A report's `progress` (`{steps, marks, last_step}`), if well-formed
    /// (web `progressFromReport`).
    private static func progress(_ raw: Any?) -> DelegationProgress? {
        guard let obj = raw as? [String: Any], let n = obj["steps"] as? NSNumber, !ToolJSONFormat.isBoolean(n),
              n.doubleValue >= 0, n.doubleValue == n.doubleValue.rounded() else { return nil }
        let marks = (obj["marks"] as? [Any] ?? []).filter { ($0 as? String) == "ok" || ($0 as? String) == "failed" }
        let last = (obj["last_step"] as? String)?
            .split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return DelegationProgress(steps: max(n.intValue, marks.count),
                                  lastStep: (last?.isEmpty ?? true) ? nil : last)
    }

    private static func childConversationIdOf(_ obj: [String: Any]) -> Int? {
        guard let n = obj["child_conversation_id"] as? NSNumber, !ToolJSONFormat.isBoolean(n) else { return nil }
        return n.intValue
    }

    private static func findTasksArray(_ obj: [String: Any]) -> (tasks: [Any], trusted: Bool)? {
        if let sc = obj["structuredContent"] as? [String: Any], let tasks = sc["tasks"] as? [Any] {
            return (tasks, true)
        }
        if let tasks = obj["tasks"] as? [Any] { return (tasks, false) }
        if let contentText = firstContentText(obj), let embedded = EmbeddedJSON.extractObject(contentText),
           let tasks = embedded["tasks"] as? [Any] {
            return (tasks, false)
        }
        return nil
    }

    private static func findTaskIds(_ value: Any?, depth: Int = 0) -> [String] {
        guard depth <= 4, let value else { return [] }
        if let s = value as? String, let obj = ToolJSONFormat.parseObject(s) {
            return findTaskIds(obj, depth: depth + 1)
        }
        guard let obj = value as? [String: Any] else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        func push(_ v: Any?) {
            if let s = v as? String, !s.isEmpty, !seen.contains(s) { seen.insert(s); out.append(s) }
        }
        if let ids = obj["task_ids"] as? [Any] { ids.forEach(push) }
        push(obj["task_id"])
        if !out.isEmpty { return out }
        for key in ["arguments", "input", "params", "payload", "_meta"] where obj[key] != nil {
            let found = findTaskIds(obj[key], depth: depth + 1)
            if !found.isEmpty { return found }
        }
        return out
    }

    // Backend protocol strings (English-only), never localized UI copy. Recognizes
    // the "still running" result so a content-only host (no structured status)
    // doesn't degrade a running task's badge to a false "ok".
    private static let runningMarker = "running."
    private static let runningReplyPrefix = "latest sub-agent reply:"
    private static let runningBlockedPrefix = "awaiting your decision:"
    private static let legacyRunningSentinel = "sub-agent is still running in the background."

    private static func textRunningStatus(_ text: String?) -> TaskStatus? {
        guard let text else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == legacyRunningSentinel { return .running }
        guard let nl = normalized.firstIndex(of: "\n") else {
            return normalized == runningMarker ? .running : nil
        }
        let firstLine = String(normalized[..<nl]).trimmingCharacters(in: .whitespaces)
        guard firstLine == runningMarker else { return nil }
        let secondLine = String(normalized[normalized.index(after: nl)...]).drop(while: { $0 == " " || $0 == "\t" })
        return secondLine.hasPrefix(runningReplyPrefix) || secondLine.hasPrefix(runningBlockedPrefix) ? .running : nil
    }

    /// Whether a running report's text carries the backend's blocked note
    /// (web `textIsBlocked`): the second line opens with it.
    static func textIsBlocked(_ text: String?) -> Bool {
        guard let text, let nl = text.firstIndex(of: "\n") else { return false }
        return text[text.index(after: nl)...]
            .drop(while: { $0.isWhitespace })
            .lowercased()
            .hasPrefix(runningBlockedPrefix)
    }
}

// MARK: - resume_delegation (refused)

/// A `resume_delegation` the broker refused: the task it named and what the
/// broker said. It revived nothing, so it is drawn as just that — never as a
/// sub-agent that came back (web: `DelegationResumeRow` falls back to the
/// workbench row, which states the reason).
struct ResumeRefusal: Equatable {
    /// The `task_id` argument.
    var taskId: String?
    /// The broker's explanation as it wrote it ("Not resumed: the task already
    /// completed — …"); nil when the result carried no text at all.
    var message: String?
}

extension DelegationModel {
    /// The refusal a `resume_delegation` call came back with; nil for any other
    /// call, for a resume that went ahead, and for one still in flight.
    static func resumeRefusal(_ vm: ToolCallVM) -> ResumeRefusal? {
        // The name first: it is memoized, and this runs for every card drawn.
        guard ToolNameNormalizer.normalizeToolName(vm.toolName).lowercased() == "resume_delegation",
              vm.hasOutput, isRefusedResume(vm) else { return nil }
        let pair = outputError(vm)
        return ResumeRefusal(
            taskId: ActivityJSON.findStringFieldDeep(vm.input, key: "task_id"),
            message: refusalMessage(output: pair.output, errorText: pair.errorText)
        )
    }

    /// The text a refused resume explains itself with. The report's own
    /// `message` is preferred when it carries the refusal — for a `completed`
    /// report the content text a host shows may be the child's earlier output
    /// instead — then whatever the result shows, then the raw result.
    static func refusalMessage(output: String?, errorText: String?) -> String? {
        let raw = (output ?? errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        var candidates: [String?] = []
        if let obj = parseResultObject(raw).obj {
            let structured = obj["structuredContent"] as? [String: Any]
            let embedded = firstContentText(obj).flatMap(EmbeddedJSON.extractObject)
            candidates = [structured?["message"] as? String, obj["message"] as? String,
                          embedded?["message"] as? String]
        }
        candidates.append(parseStatusReport(output: output, errorText: errorText).text)
        candidates.append(raw)
        let texts = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return texts.first { ToolNameNormalizer.jsTrimStart($0).utf16.starts(with: refusedResumeText.utf16) }
            ?? texts.first
    }
}
