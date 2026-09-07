import Foundation

/// The visual lifecycle of a tool call. Persisted calls are `.done`/`.error`
/// (paired with their result) or `.running` (no result block); live calls move
/// through `.running` → `.done`/`.error` as ACP updates arrive.
enum ToolCallState {
    case inputStreaming
    case running
    case done
    case error
}

/// Coarse category a tool falls into — drives the icon and the group summary
/// ("Read 3 files · Edited 2 files"). Mirrors the codeg client's tool-kind
/// buckets.
enum ToolKindBucket {
    case read, edit, search, execute, web, todo, task, taskMgmt, other
}

/// A unified, view-ready model for one tool call. Both the persisted path
/// (`tool_use` + `tool_result` paired) and the live path (`LiveToolCall`) adapt
/// into this, so the card UI is shared. Derived fields (title, icon, bucket,
/// diff) are computed once at construction.
struct ToolCallVM: Identifiable {
    let id: String
    let rawName: String
    let kind: String
    let state: ToolCallState
    let input: String?
    let output: String?
    /// ACP "rendered content" — for an edit this is a unified diff. Live only.
    let content: String?
    let isError: Bool
    /// ACP extensibility metadata (`meta`). For `delegate_to_agent` it carries
    /// `codeg.delegation = { status, error_code?, text_preview?, duration_ms? }`,
    /// the authoritative terminal status the delegate card prefers over the ack.
    let meta: AnyJSON?

    // Precomputed derived
    let displayTitle: String
    let bucket: ToolKindBucket
    /// Non-nil for a codeg-mcp companion tool (delegate / status / cancel / ask),
    /// which renders through its own card instead of `ToolCallCard`.
    let companion: CompanionKind?
    let icon: String
    let diffFiles: [DiffFile]?

    init(id: String, rawName: String, kind: String, state: ToolCallState,
         input: String?, output: String?, content: String?, isError: Bool,
         meta: AnyJSON? = nil) {
        // Grok's plan-mode tools carry their authoritative identity in
        // `_meta["x.ai/tool"].kind`, while the `title` we're handed as `rawName`
        // MUTATES across the lifecycle (`enter_plan_mode` → "Plan: Enter" → "Plan
        // mode entered"). Resolve them to the canonical name up front so the live
        // stream lands on the same identity the persisted path reads from
        // `x.ai/tool.name` — and so the card's title stops changing mid-stream.
        let resolvedName = ToolDerive.grokPlanModeName(meta) ?? rawName
        self.id = id
        self.rawName = resolvedName
        self.kind = kind
        self.state = state
        self.input = input
        self.output = output
        self.content = content
        self.isError = isError
        self.meta = meta

        let parsed = ToolDerive.parseJSON(input)
        let b = ToolDerive.bucket(name: resolvedName, kind: kind)
        let comp = CompanionDetect.kind(name: resolvedName, input: input, parsed: parsed)
        self.bucket = b
        self.companion = comp
        self.displayTitle = ToolDerive.title(name: resolvedName, bucket: b, input: input, parsed: parsed)
        self.icon = comp.map(ToolDerive.companionIcon) ?? ToolDerive.icon(bucket: b, name: resolvedName)
        self.diffFiles = ToolDerive.diff(bucket: b, input: input, output: output, content: content, parsed: parsed)
    }

    var trimmedOutput: String { (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasOutput: Bool { !trimmedOutput.isEmpty }
    /// Bash/shell output renders in a terminal-ish code block.
    var isCommand: Bool { bucket == .execute }
    /// A plan-*mode* transition (Claude's `EnterPlanMode`/`ExitPlanMode`, Grok's
    /// `enter_plan_mode`/`exit_plan_mode`, Cline's `switch_mode`). A mode signal,
    /// not a work tool, so it renders standalone instead of folding into a group.
    var isPlanMode: Bool { ToolDerive.isPlanModeName(rawName) }
}

/// One ordered piece of a rendered assistant turn. The persisted and live
/// adapters both produce this list; `TranscriptTimeline` maps each part to a
/// timeline node and `NodeBody` renders it.
enum RenderPart {
    case text(String)                                   // finalized prose → block markdown
    case reasoning(text: String)                        // finalized reasoning
    case liveText(LiveTextRun, streaming: Bool)          // streaming prose (plain, @Bindable)
    case liveReasoning(LiveTextRun, streaming: Bool)
    /// A message the user sent while the reply was streaming, carried as the user
    /// turn it renders as. It breaks the grouping runs below, so the answer to it
    /// never folds into what the agent was saying before it arrived.
    case userMessage(MessageTurn)
    case tool(ToolCallVM)
    case toolGroup(items: [ToolCallVM], streaming: Bool)
    /// A run of consecutive `get_delegation_status` polls, merged into one card.
    case delegationStatusGroup([ToolCallVM])
    /// A run of consecutive task-management calls (`TaskCreate`/`TaskUpdate`/
    /// `TaskList`/`TaskGet`), merged into one evolving checklist card.
    case taskGroup([ToolCallVM])
    case image(ImageData, caption: String?)
    /// A context compaction (`_meta.contextCompaction`) — a conversation boundary
    /// marker, not a tool call. Rendered as a chrome-less centered divider; the
    /// token counts are Grok-only (codex sends none).
    case compaction(before: Int?, after: Int?, running: Bool)
    case unknown(type: String)
}

// MARK: - Adapters

/// Adapts persisted `MessageTurn`s and live `LiveTurn`s into `[RenderPart]`.
/// Main-actor isolated: it reads the `@MainActor` live models and is only ever
/// called from a view body.
@MainActor
enum MessageRender {

    static func adaptTurn(_ turn: MessageTurn) -> [RenderPart] {
        if let cached = turnCache[turn] { return cached }

        let blocks = turn.blocks
        var consumed = Set<Int>()
        var parts: [RenderPart] = []

        for (idx, block) in blocks.enumerated() where !consumed.contains(idx) {
            switch block {
            case .text(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(t)) }
            case .thinking(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.reasoning(text: t)) }
            case .image(let img):
                parts.append(.image(img, caption: nil))
            case .imageGeneration(let prompt, let img):
                if let img { parts.append(.image(img, caption: prompt)) }
                else if let prompt, !prompt.isEmpty { parts.append(.text(prompt)) }
            case .toolUse(let toolID, let name, let inputPreview, let meta):
                let resultIdx = findResult(in: blocks, after: idx, toolID: toolID, consumed: consumed)
                var output: String?
                var isErr = false
                if let r = resultIdx, case .toolResult(_, let outPreview, let e) = blocks[r] {
                    output = outPreview; isErr = e; consumed.insert(r)
                }
                let state: ToolCallState = resultIdx == nil ? .running : (isErr ? .error : .done)
                // A compaction is a boundary marker, not a call: it renders as a
                // divider between turns, so it never becomes a `ToolCallVM` (and so
                // can't be swept into a tool group).
                if ContextCompaction.matches(meta) {
                    let counts = ContextCompaction.tokens(meta)
                    parts.append(.compaction(before: counts.before, after: counts.after,
                                             running: state == .running))
                    continue
                }
                parts.append(.tool(ToolCallVM(
                    id: toolID ?? "tool-\(idx)", rawName: name, kind: "", state: state,
                    input: inputPreview, output: output, content: nil, isError: isErr, meta: meta)))
            case .toolResult(let toolID, let outPreview, let e):
                // Orphan result (no preceding tool_use) — show it on its own.
                parts.append(.tool(ToolCallVM(
                    id: toolID ?? "result-\(idx)", rawName: "result", kind: "", state: e ? .error : .done,
                    input: nil, output: outPreview, content: nil, isError: e)))
            case .unknown(let type):
                parts.append(.unknown(type: type))
            }
        }

        let grouped = group(parts)
        cacheTurn(turn, grouped)
        return grouped
    }

    static func adaptLive(_ turn: LiveTurn) -> [RenderPart] {
        var parts: [RenderPart] = []
        let segments = turn.segments
        // Only the *final* segment is still growing — it alone carries the
        // streaming flag (the typing caret + cache bypass). Earlier text/reasoning
        // runs are frozen the moment the agent moved on to the next segment, so
        // they render as finalized (no caret, cached). Without this, every text
        // segment showed its own blinking caret.
        let lastIndex = segments.count - 1
        for (idx, segment) in segments.enumerated() {
            let isLast = idx == lastIndex
            switch segment {
            case .text(let run):
                parts.append(.liveText(run, streaming: turn.isStreaming && isLast))
            case .thinking(let run):
                parts.append(.liveReasoning(run, streaming: turn.isStreaming && isLast))
            case .userMessage(let message):
                parts.append(.userMessage(MessageTurn(
                    id: "u-\(message.id)",
                    role: .user,
                    blocks: [.text(message.text)],
                    timestamp: message.sentAt
                )))
            case .tool(let call):
                let state: ToolCallState = call.isFinished ? (call.isError ? .error : .done) : .running
                // Same boundary-marker treatment as the persisted path: codex emits
                // the `Context compacting` → `Context compacted` pair on one id, so
                // the divider flips from running to settled in place.
                if ContextCompaction.matches(call.meta) {
                    let counts = ContextCompaction.tokens(call.meta)
                    parts.append(.compaction(before: counts.before, after: counts.after,
                                             running: state == .running))
                    continue
                }
                parts.append(.tool(ToolCallVM(
                    id: call.id, rawName: call.title, kind: call.kind, state: state,
                    input: call.rawInput, output: call.rawOutput, content: call.content, isError: call.isError,
                    meta: call.meta)))
            }
        }
        return group(parts)
    }

    /// The full grouping pipeline (mirroring the web): first collapse generic tool
    /// runs into `toolGroup`s, then merge consecutive `get_delegation_status` polls
    /// into one `delegationStatusGroup`, then merge consecutive task-management
    /// calls into one `taskGroup` checklist.
    static func group(_ parts: [RenderPart]) -> [RenderPart] {
        groupConsecutiveTaskOps(groupConsecutiveDelegationStatus(groupConsecutiveTools(parts)))
    }

    /// Collapse runs of 2+ consecutive tool calls into a `toolGroup`. Agent-like
    /// tools (`.task` bucket) and the codeg-mcp companion tools (their own rich
    /// cards) always stay standalone; text / reasoning / images break a run.
    static func groupConsecutiveTools(_ parts: [RenderPart]) -> [RenderPart] {
        var out: [RenderPart] = []
        var run: [ToolCallVM] = []

        func flush() {
            if run.count >= 2 {
                let streaming = run.contains { $0.state == .running || $0.state == .inputStreaming }
                out.append(.toolGroup(items: run, streaming: streaming))
            } else if let only = run.first {
                out.append(.tool(only))
            }
            run = []
        }

        for part in parts {
            // Agent-dispatch (`.task`), task-management (`.taskMgmt`), plan-mode
            // transitions, and the codeg-mcp companion tools each render on their
            // own, so they never fold into a generic tool run.
            if case .tool(let vm) = part, vm.bucket != .task, vm.bucket != .taskMgmt,
               !vm.isPlanMode, vm.companion == nil {
                run.append(vm)
            } else {
                flush()
                out.append(part)
            }
        }
        flush()
        return out
    }

    /// Wrap each run of consecutive `get_delegation_status` polls (left standalone
    /// by `groupConsecutiveTools`) into a single `delegationStatusGroup`. Any other
    /// part — text, a tool group, the delegate / cancel / ask cards — breaks the
    /// run, so only genuinely consecutive polls collapse. Even a single poll is
    /// wrapped, so the merged-card "returned-running reads as a settled snapshot"
    /// resolution applies uniformly. Consecutive assistant turns are merged before
    /// adaptation (`TranscriptTimeline.merge`), so a multi-round poll sequence lands
    /// consecutively here and collapses without a separate cross-turn pass.
    static func groupConsecutiveDelegationStatus(_ parts: [RenderPart]) -> [RenderPart] {
        var out: [RenderPart] = []
        var buffer: [ToolCallVM] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(.delegationStatusGroup(buffer))
            buffer = []
        }

        for part in parts {
            if case .tool(let vm) = part, vm.companion == .delegationStatus {
                buffer.append(vm)
            } else {
                flush()
                out.append(part)
            }
        }
        flush()
        return out
    }

    /// Wrap each run of consecutive *successful* task-management calls (`.taskMgmt`)
    /// into a single `taskGroup`, so a `TaskCreate ×5` burst becomes one checklist
    /// rather than five cards. Even a lone op is wrapped, so every successful task
    /// surface renders through the one checklist card. Mirrors
    /// `groupConsecutiveDelegationStatus`.
    ///
    /// A FAILED task op is deliberately left standalone (it breaks the run): a
    /// failed `TaskUpdate {status: completed}` must not render a green "completed"
    /// row as if it had applied, and a failed `TaskList`/`TaskGet` must surface its
    /// error output — both of which the standard `ToolCallCard` error path does. So
    /// the checklist only ever reflects calls that actually succeeded.
    static func groupConsecutiveTaskOps(_ parts: [RenderPart]) -> [RenderPart] {
        var out: [RenderPart] = []
        var buffer: [ToolCallVM] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(.taskGroup(buffer))
            buffer = []
        }

        for part in parts {
            if case .tool(let vm) = part, vm.bucket == .taskMgmt, vm.companion == nil, !vm.isError {
                buffer.append(vm)
            } else {
                flush()
                out.append(part)
            }
        }
        flush()
        return out
    }

    private static func findResult(in blocks: [ContentBlock], after idx: Int, toolID: String?, consumed: Set<Int>) -> Int? {
        // Prefer an exact id match anywhere later.
        if let toolID {
            for j in (idx + 1)..<blocks.count where !consumed.contains(j) {
                if case .toolResult(let rid, _, _) = blocks[j], rid == toolID { return j }
            }
        }
        // Otherwise the next unconsumed result — but stop at the next tool_use so
        // we don't steal a later call's result when ids are missing.
        for j in (idx + 1)..<blocks.count where !consumed.contains(j) {
            if case .toolUse = blocks[j] { break }
            if case .toolResult = blocks[j] { return j }
        }
        return nil
    }

    // Persisted adaptation is stable per turn *value*; memoize so a recycled List
    // row doesn't re-pair/re-parse. Live turns are never cached (they mutate).
    //
    // The key is the whole `MessageTurn`, NOT `turn.id`: this is a process-wide
    // static cache shared by every conversation, and codeg's turn ids are only
    // unique *within* a conversation (they are not global), so keying by id alone
    // let conversation B reuse conversation A's render whenever their ids collided
    // — the transcript showing "another conversation's messages". Dictionary
    // lookup compares full value equality (hash is only a bucket hint), so a
    // colliding id with different content can never produce a false hit, and a
    // turn whose content actually changed re-derives correctly.
    private static var turnCache: [MessageTurn: [RenderPart]] = [:]
    private static var turnOrder: [MessageTurn] = []
    private static let turnLimit = 400

    private static func cacheTurn(_ turn: MessageTurn, _ parts: [RenderPart]) {
        turnCache[turn] = parts
        turnOrder.append(turn)
        if turnOrder.count > turnLimit {
            let evicted = turnOrder.removeFirst()
            turnCache.removeValue(forKey: evicted)
        }
    }
}

// MARK: - Derivation

/// Pure helpers that turn a tool name + parsed input into a human title, an
/// icon, a bucket, and (for edits) a diff. Mirrors the codeg client's
/// `deriveToolTitle` / `getToolIcon` / tool-kind classifier.
enum ToolDerive {

    static func parseJSON(_ s: String?) -> [String: Any]? {
        guard let s, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Descend into a wrapper object (`input`/`arguments`/…) when the args were
    /// nested; otherwise the object itself is the args.
    static func effectiveArgs(_ parsed: [String: Any]?) -> [String: Any]? {
        guard let parsed else { return nil }
        for key in ["input", "arguments", "params", "payload"] {
            if let inner = parsed[key] as? [String: Any] { return inner }
        }
        return parsed
    }

    /// Pull the shell command out of a tool input. Mirrors web
    /// `commandFromUnknownValue` + `extractCommandFromUnknownInput` and handles
    /// every shape a command arrives in: a parsed object's
    /// `command`/`cmd`/`script` (string or argv array, incl. nested
    /// `input`/`arguments` wrappers), a JSON-encoded string or argv array, and —
    /// crucially — a BARE command string (Codex persists `exec_command` input as
    /// the raw command, not JSON), which otherwise fails to parse and drops the
    /// title to a generic "Bash".
    static func extractCommand(input: String?, parsed: [String: Any]?) -> String? {
        if let parsed, let c = commandFromValue(parsed) { return c }
        guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // A JSON fragment the object-parse missed (a quoted string or argv array).
        if let any = ToolJSONFormat.parseAny(raw), let c = commandFromValue(any) { return c }
        // A bare, non-JSON string is itself the command; don't echo an
        // unparseable `{…}`/`[…]` blob as if it were one.
        if raw.hasPrefix("{") || raw.hasPrefix("[") { return nil }
        return raw
    }

    private static func commandFromValue(_ value: Any) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let arr = value as? [Any] {
            let parts = arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        guard let obj = value as? [String: Any] else { return nil }
        for key in ["command", "cmd", "script", "args", "argv", "command_args"] {
            if let v = obj[key], let c = commandFromValue(v) { return c }
        }
        for key in ["input", "arguments", "params", "payload"] {
            if let v = obj[key], let c = commandFromValue(v) { return c }
        }
        return nil
    }

    static func title(name: String, bucket: ToolKindBucket, input: String?, parsed: [String: Any]?) -> String {
        let n = canonical(name)
        let args = effectiveArgs(parsed)
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = args?[k] as? String, !v.isEmpty { return v } }
            return nil
        }

        // Plan-mode transitions get a fixed human title. Grok's own titles mutate
        // as the call progresses, so deriving from the name keeps the card stable.
        if isPlanModeName(name) {
            let normalized = n.replacingOccurrences(of: "_", with: "")
            if normalized == "enterplanmode" { return "Entered plan mode" }
            if normalized == "exitplanmode" { return "Plan ready" }
            return "Switched mode"
        }

        // Execute/shell tools show the actual command. Keyed off the `bucket`
        // rather than the name: the live path identifies shells by the ACP
        // `kind` and passes an arbitrary agent-supplied title as the "name", and
        // Codex persists `exec_command` input as a BARE command string (not
        // JSON) — both previously slipped past the name switch and fell back to
        // a generic "Bash". Show the command itself (per request); description
        // and the literal label are only last resorts.
        if bucket == .execute {
            if let c = extractCommand(input: input, parsed: parsed) { return simplifyCommand(c) }
            if let d = str(["description"]) { return d }
            return "Bash"
        }

        // Task-management tools render through `TaskListCard`, but a sensible title
        // still feeds the gutter marker / accessibility.
        if bucket == .taskMgmt { return taskMgmtTitle(name: name, args: args) }

        switch n {
        case "read", "read_file", "readfile", "cat", "view":
            if let p = str(["file_path", "path", "filename", "file", "target_file"]) { return "Read \(PathFormat.short(p))" }
            return display(name)
        case "edit", "str_replace", "str_replace_editor", "str_replace_based_edit_tool",
             "apply_patch", "applypatch", "patch", "multiedit", "edit_file":
            if let count = editFileCount(args: args), count > 1 { return "Edit (\(count) files)" }
            if let p = str(["file_path", "path", "filename", "file", "target_file"]) { return "Edit \(PathFormat.short(p))" }
            return "Edit"
        case "write", "write_file", "writefile", "create_file", "notebookedit", "notebook_edit":
            if let p = str(["file_path", "path", "filename", "file", "target_file"]) { return "Write \(PathFormat.short(p))" }
            return "Write"
        case "grep", "ripgrep", "grep_search", "search_files", "search":
            if let p = str(["pattern", "query", "regex", "q"]) { return "Grep \(truncate(p, 50))" }
            return "Grep"
        case "glob", "find", "file_search":
            if let p = str(["pattern", "glob", "path", "query"]) { return "Glob \(truncate(p, 50))" }
            return "Glob"
        case "ls", "list_dir", "list_files":
            if let p = str(["path", "dir", "directory"]) { return "List \(PathFormat.short(p))" }
            return "List"
        case "webfetch", "web_fetch", "fetch":
            if let u = str(["url"]) { return "WebFetch \(host(u))" }
            return "WebFetch"
        case "websearch", "web_search":
            if let q = str(["query", "q"]) { return "WebSearch: \(truncate(q, 50))" }
            return "WebSearch"
        case "todowrite", "todo_write", "update_todo_list", "todos":
            if let (done, total) = todoCounts(args: args) { return "Todos (\(done)/\(total))" }
            return "Todos"
        case "task", "taskcreate", "agent", "dispatch_agent", "new_task", "delegate_to_agent":
            if let sub = str(["subagent_type", "agent_type", "description", "subject"]) {
                return display(name) + ": " + truncate(sub, 50)
            }
            return display(name)
        case "skill":
            if let s = str(["name", "skill", "command"]) { return "Skill: \(s)" }
            return "Skill"
        default:
            if let v = firstStringValue(args) { return "\(display(name)): \(truncate(v, 50))" }
            return display(name)
        }
    }

    // Exact canonical-name buckets. Mirrors the web `classifyToolKind` /
    // `EXACT_TOOL_NAME_ALIASES` approach: match KNOWN names exactly rather than
    // substring-`contains`. The old `contains` heuristic mis-bucketed any MCP
    // tool whose name happened to embed a keyword — e.g. `mcp__db__run_query`
    // hit `contains("run")` → `.execute` → the Bash body dumped its raw JSON.
    // An unknown tool must fall through to `.other` so it renders structured
    // fields, not a guessed per-type body.
    private static let readNames: Set<String> = ["read", "read_file", "readfile", "read_text_file", "cat", "view"]
    private static let editNames: Set<String> = [
        "edit", "str_replace", "str_replace_editor", "str_replace_based_edit_tool",
        "apply_patch", "applypatch", "patch", "multiedit", "edit_file", "update_file",
        "write", "write_file", "writefile", "create_file", "notebookedit", "notebook_edit",
        "write_to_file", "replace_in_file",
    ]
    private static let searchNames: Set<String> = [
        "grep", "ripgrep", "grep_search", "search_files", "search", "searchtext", "search_text",
        "glob", "find", "file_search", "ls", "list_dir", "list_files", "list_code_definition_names",
    ]
    private static let executeNames: Set<String> = [
        "bash", "shell", "sh", "exec", "exec_command", "execute", "execute_command",
        "run_command", "command", "run_terminal_cmd", "terminal", "write_stdin",
    ]
    private static let webNames: Set<String> = [
        "webfetch", "web_fetch", "fetch", "websearch", "web_search", "browser", "browser_action",
    ]
    private static let todoNames: Set<String> = ["todowrite", "todo_write", "update_todo_list", "todos"]
    // Agent-DISPATCH tools (spawn a sub-agent) — distinct from the task-MANAGEMENT
    // tools below, which manage a to-do list.
    private static let taskNames: Set<String> = [
        "task", "agent", "dispatch_agent", "new_task",
        "delegate_to_agent", "delegate_task", "subagent", "spawn_agent", "call_omo_agent",
    ]
    /// The harness task-management tools — a to-do list, NOT sub-agent dispatch.
    /// Bucketed separately so they render as an evolving checklist (`TaskListCard`)
    /// with checklist iconography instead of the agent-dispatch "person.2".
    private static let taskMgmtNames: Set<String> = [
        "taskcreate", "taskupdate", "tasklist", "taskget",
        "task_create", "task_update", "task_list", "task_get",
        "createtask", "updatetask", "listtasks", "gettask", "addtask",
    ]

    static func bucket(name: String, kind: String) -> ToolKindBucket {
        // The ACP `kind` hint (live tools carry an authoritative category) wins.
        switch kind.lowercased() {
        case "read": return .read
        case "edit", "write", "delete", "move": return .edit
        case "search": return .search
        case "execute", "command", "bash", "shell", "terminal": return .execute
        case "fetch", "web": return .web
        default: break
        }
        let n = canonical(name)
        if readNames.contains(n) { return .read }
        if todoNames.contains(n) { return .todo }
        if taskMgmtNames.contains(n) { return .taskMgmt }
        if taskNames.contains(n) { return .task }
        if editNames.contains(n) { return .edit }
        if searchNames.contains(n) { return .search }
        if executeNames.contains(n) { return .execute }
        if webNames.contains(n) { return .web }
        return .other
    }

    /// Grok stamps the authoritative tool identity in `_meta["x.ai/tool"]`
    /// (`{name, kind, namespace, label}`). For its plan-mode tools this returns the
    /// canonical `enter_plan_mode` / `exit_plan_mode`; nil for every other Grok tool
    /// and every non-Grok host, so their existing name resolution is preserved.
    /// Keyed on the stable `kind` discriminator, which — unlike `title` — does not
    /// mutate across the tool_call lifecycle.
    static func grokPlanModeName(_ meta: AnyJSON?) -> String? {
        switch meta?["x.ai/tool"]?["kind"]?.string {
        case "enter_plan": return "enter_plan_mode"
        case "exit_plan": return "exit_plan_mode"
        default: return nil
        }
    }

    /// Plan-*mode* transition tools. Mirrors the web `isPlanModeToolName`:
    /// deliberately NOT the looser "contains plan" test, so Codex's `update_plan`
    /// (a real checklist) keeps its own rendering.
    static func isPlanModeName(_ name: String) -> Bool {
        switch canonical(name).replacingOccurrences(of: "_", with: "") {
        case "enterplanmode", "exitplanmode", "switchmode": return true
        default: return false
        }
    }

    static func icon(bucket: ToolKindBucket, name: String) -> String {
        // A mode signal, not a work tool — same checklist glyph the plan node uses.
        if isPlanModeName(name) { return "checklist" }
        switch bucket {
        case .read: return "doc.text"
        case .edit: return "square.and.pencil"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .web: return "globe"
        case .todo: return "checklist"
        case .task: return "person.2"
        case .taskMgmt: return "checklist"
        case .other: return "wrench.and.screwdriver"
        }
    }

    /// Gutter / card icon for a codeg-mcp companion tool.
    static func companionIcon(_ kind: CompanionKind) -> String {
        switch kind {
        case .delegate:         return "person.2"
        case .delegationStatus: return "arrow.triangle.2.circlepath"
        case .cancelDelegation: return "xmark.circle"
        case .askQuestion:      return "questionmark.bubble"
        }
    }

    static func diff(bucket: ToolKindBucket, input: String?, output: String?, content: String?, parsed: [String: Any]?) -> [DiffFile]? {
        guard bucket == .edit else { return nil }
        // Priority: live ACP content → persisted output (Claude) → raw input
        // (apply_patch) → synthesize from old/new strings.
        for candidate in [content, output, input].compactMap({ $0 }) {
            if UnifiedDiff.looksLikeDiff(candidate), let files = UnifiedDiff.parse(candidate) { return files }
        }
        if let args = effectiveArgs(parsed) {
            let oldS = (args["old_string"] as? String) ?? (args["old_str"] as? String)
            let newS = (args["new_string"] as? String) ?? (args["new_str"] as? String)
            if let oldS, let newS {
                let path = (args["file_path"] as? String) ?? (args["path"] as? String) ?? "edit"
                return synthesizeDiff(path: path, old: oldS, new: newS)
            }
        }
        return nil
    }

    // MARK: helpers

    private static func canonical(_ name: String) -> String {
        var n = name.lowercased()
        if let r = n.range(of: "__", options: .backwards) { n = String(n[r.upperBound...]) }
        return n
    }

    static func display(_ name: String) -> String {
        var n = name
        if let r = n.range(of: "__", options: .backwards) { n = String(n[r.upperBound...]) }
        return n
    }

    private static func editFileCount(args: [String: Any]?) -> Int? {
        if let changes = args?["changes"] as? [Any] { return changes.count }
        if let edits = args?["edits"] as? [Any] { return edits.count }
        if let patch = (args?["patch"] as? String) ?? (args?["input"] as? String), patch.contains("*** ") {
            let n = patch.components(separatedBy: "\n").filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("*** Add File:") || t.hasPrefix("*** Update File:") || t.hasPrefix("*** Delete File:")
            }.count
            if n > 0 { return n }
        }
        return nil
    }

    /// A title for a task-management call — used for the gutter marker / a11y; the
    /// `TaskListCard` computes its own header. Mirrors `TaskOpParse`'s name routing.
    private static func taskMgmtTitle(name: String, args: [String: Any]?) -> String {
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = args?[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        // A task id may be a JSON string OR number — match `TaskOpParse.idStr` so a
        // numeric `{ "taskId": 9 }` titles "Update task #9", not "Update task".
        func id(_ keys: [String]) -> String? {
            for k in keys {
                guard let v = args?[k] else { continue }
                if let s = v as? String, !s.isEmpty { return s }
                if let n = v as? NSNumber, !ToolJSONFormat.isBoolean(n) { return n.stringValue }
            }
            return nil
        }
        switch TaskOpParse.kind(of: name) {
        case .create:
            if let s = str(["subject", "title"]) { return "New task: " + truncate(s, 50) }
            return "New task"
        case .update:
            if let tid = id(["taskId", "task_id", "id"]) { return "Update task #\(tid)" }
            return "Update task"
        case .get:
            if let tid = id(["taskId", "task_id", "id"]) { return "Task #\(tid)" }
            return "Task details"
        case .list:
            return "Task list"
        case .none:
            return display(name)
        }
    }

    private static func todoCounts(args: [String: Any]?) -> (Int, Int)? {
        guard let todos = (args?["todos"] as? [[String: Any]]) ?? (args?["todoList"] as? [[String: Any]]) else { return nil }
        let total = todos.count
        let done = todos.filter { ($0["status"] as? String) == "completed" }.count
        return (done, total)
    }

    private static func firstStringValue(_ args: [String: Any]?) -> String? {
        guard let args else { return nil }
        let skip: Set<String> = ["id", "tool_use_id", "tool_call_id", "type"]
        for k in args.keys.sorted() where !skip.contains(k.lowercased()) {
            if let s = args[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func simplifyCommand(_ c: String) -> String {
        var cmd = c.trimmingCharacters(in: .whitespacesAndNewlines)
        // Peel nested shell wrappers like `/bin/zsh -lc '<cmd>'` or
        // `/usr/bin/env bash -c "<cmd>"` so the title is the real command, not
        // the launcher. Mirrors web `simplifyShellCommand` (loops for nesting).
        let wrapper = #"^(?:/usr/bin/env\s+)?(?:/[^\s]+/)?(?:bash|zsh|sh)\s+-l?c\s+"#
        for _ in 0..<6 {
            guard let r = cmd.range(of: wrapper, options: [.regularExpression, .caseInsensitive]) else { break }
            let inner = unwrapQuoted(cmd[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
            if inner.isEmpty || inner == cmd { break }
            cmd = inner
        }
        let firstLine = cmd.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? cmd
        return truncate(firstLine, 80)
    }

    /// Strip a single layer of matching surrounding quotes from an unwrapped
    /// shell argument (`'<cmd>'` / `"<cmd>"`), unescaping the double-quoted form.
    private static func unwrapQuoted(_ command: String) -> String {
        let t = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return t }
        if t.hasPrefix("'") && t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
        if t.hasPrefix("\"") && t.hasSuffix("\"") {
            return String(t.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }

    private static func host(_ url: String) -> String {
        if let u = URL(string: url), let h = u.host { return h }
        return truncate(url, 40)
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    private static func synthesizeDiff(path: String, old: String, new: String) -> [DiffFile] {
        var rows: [DiffRow] = []
        for l in old.split(separator: "\n", omittingEmptySubsequences: false) {
            rows.append(DiffRow(kind: .deleted, oldLine: nil, newLine: nil, text: String(l)))
        }
        for l in new.split(separator: "\n", omittingEmptySubsequences: false) {
            rows.append(DiffRow(kind: .added, oldLine: nil, newLine: nil, text: String(l)))
        }
        let dels = old.split(separator: "\n", omittingEmptySubsequences: false).count
        let adds = new.split(separator: "\n", omittingEmptySubsequences: false).count
        return [DiffFile(path: path, oldPath: nil, mode: .modified, additions: adds, deletions: dels,
                         hunks: [DiffHunk(header: nil, rows: rows)])]
    }
}

/// Shorten a file path to its last two segments ("src/foo.ts").
enum PathFormat {
    static func short(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: .whitespaces)
        let comps = clean.split(separator: "/").map(String.init)
        if comps.count <= 2 { return comps.joined(separator: "/") }
        return comps.suffix(2).joined(separator: "/")
    }
}
