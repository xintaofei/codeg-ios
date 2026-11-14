import Foundation
import os

/// Tool-name normalization — port of the web's `src/lib/tool-call-normalization.ts`
/// (codeg 0.44), plus the pieces of `codex-command-action.ts` / `collab-tool.ts`
/// it reads.
///
/// Every agent names its tools differently, and the live stream names them
/// differently again from the transcript a reload reads back: a live call
/// carries a human title, an ACP `kind`, a streamed input and a `_meta` blob,
/// while history keeps the raw tool name. `normalizeToolName` collapses a raw
/// name to the canonical one the renderers dispatch on; `inferLiveToolName`
/// derives that same canonical name from a live call's frames, so a call draws
/// the same card while it runs and after a reload.
///
/// Matching follows JavaScript exactly, not Swift's defaults: trimming and
/// lower-casing use JS's whitespace set and case mapping, the regular
/// expressions keep JS's ASCII `\b` / `\w` / case-insensitivity and its
/// whole-string `$`, and every prefix / index test is on UTF-16 code units.
enum ToolNameNormalizer {
    // MARK: - Names other modules dispatch on

    /// Codex code-mode script card (`codex-code-mode.ts`).
    static let codexScriptToolName = "codex_script"
    /// Unified-exec session tools (`shell-session-tool.ts`).
    static let waitToolName = "wait"
    static let writeStdinToolName = "write_stdin"
    /// The live codex collab path collapses to this (`collab-tool.ts`).
    static let collabAgentToolName = "collab_agent"

    /// `_meta` key naming the tool call that launched the sub-agent a call belongs
    /// to — the agent-neutral twin of Claude's `claudeCode.parentToolUseId`, which
    /// the backend stamps where the agent states the link some other way
    /// (OpenCode 2: only the child SESSION a sub-agent's call ran in).
    static let parentToolCallMetaKey = "codeg.parentToolCallId"

    /// The title (live) and tool name (history) of OpenCode's code-mode tool.
    private static let codeModeToolTitle = "execute"

    // MARK: - Exact aliases

    /// Raw names (lower-cased, or canonicalized) → canonical names.
    ///
    /// Why the non-obvious entries exist:
    /// - `run_terminal_command` (Grok), `shell` (Cursor), `run_command`
    ///   (Antigravity) and `powershell` (Claude Code / pi on Windows) are what the
    ///   history parsers read back out of the transcript; the live path classifies
    ///   them by input shape, so without the alias the reload drew a generic card.
    ///   The freeform `\bshell\b` matcher cannot catch "powershell".
    /// - `view_image`: codex streams it as `kind: "read"`; the rollout keeps the raw name.
    /// - `monitor` / `sandboxnetworkaccess`: Claude Code tools whose live input
    ///   looks like another tool's (see `metaNamedTools`).
    /// - `codex_script`, `wait`, `write_stdin`: MUST be exact — the freeform
    ///   `exec(ute)?` matcher would collapse them to "bash".
    /// - `spawn_subagent` (Grok): "subagent" has no word boundary before "agent".
    /// - codeg-mcp companions (`task_progress`, `task_complete`, …): the freeform
    ///   `^task` rule would otherwise swallow them; the suffix rules in
    ///   `normalizeToolName` cover the `mcp__<server>__…` forms.
    /// - `patch` / `subagent`: OpenCode 2's renamed `apply_patch` / `task`.
    /// - `ask_question`: Antigravity's native ask tool — bare name only; a
    ///   host-prefixed `*ask_question` is someone else's MCP tool.
    static let exactToolNameAliases: [String: String] = [
        "shell_command": "bash",
        "functions.shell_command": "bash",
        "run_terminal_command": "bash",
        "shell": "bash",
        "run_command": "bash",
        "powershell": "bash",
        "exec_command": "exec_command",
        "functions.exec_command": "exec_command",
        "functions.read": "read",
        "functions.edit": "edit",
        "functions.write": "write",
        "functions.apply_patch": "apply_patch",
        "change": "edit",
        "functions.change": "edit",
        "changes": "edit",
        "read_file": "read",
        "read_text_file": "read",
        "readfile": "read",
        "read file": "read",
        "view_image": "read",
        "edit_file": "edit",
        "update_file": "edit",
        "write_file": "write",
        "mcp__acp__read": "read",
        "mcp__acp__edit": "edit",
        "mcp__acp__write": "write",
        "todowrite": "todowrite",
        "todo_write": "todowrite",
        "task_update": "taskupdate",
        "task_create": "taskcreate",
        "task_list": "tasklist",
        "enter_plan_mode": "enterplanmode",
        "exit_plan_mode": "exitplanmode",
        "web_fetch": "webfetch",
        "web_search": "websearch",
        "context7_query_docs": "context7_query-docs",
        "context7_resolve_library_id": "context7_resolve-library-id",
        "agent": "agent",
        "monitor": "monitor",
        "sandboxnetworkaccess": "sandboxnetworkaccess",
        // Gemini CLI
        "searchtext": "grep",
        "search_text": "grep",
        "writefile": "write",
        "editfile": "edit",
        // Cline
        "attempt_completion": "attempt_completion",
        "ask_followup_question": "question",
        "write_to_file": "write",
        "replace_in_file": "edit",
        "execute_command": "bash",
        "list_files": "glob",
        "search_files": "grep",
        "list_code_definition_names": "grep",
        "browser_action": "webfetch",
        "use_mcp_tool": "tool",
        // Codex
        codexScriptToolName: codexScriptToolName,
        waitToolName: waitToolName,
        writeStdinToolName: writeStdinToolName,
        "spawn_agent": "agent",
        "wait_agent": "task",
        "close_agent": "task",
        "update_plan": "task",
        // Grok
        "spawn_subagent": "agent",
        "create_goal": "create_goal",
        "functions.create_goal": "create_goal",
        "update_goal": "update_goal",
        "functions.update_goal": "update_goal",
        "request_user_input": "question",
        // codeg multi-agent delegation MCP tools (server prefix varies by host)
        "delegate_to_agent": "delegate_to_agent",
        "mcp__codeg-mcp__delegate_to_agent": "delegate_to_agent",
        "mcp__codeg-delegate__delegate_to_agent": "delegate_to_agent",
        "mcp__codeg__delegate_to_agent": "delegate_to_agent",
        "get_delegation_status": "get_delegation_status",
        "cancel_delegation": "cancel_delegation",
        "resume_delegation": "resume_delegation",
        // codeg-mcp workbench companions
        "get_session_info": "get_session_info",
        "task_progress": "task_progress",
        "task_complete": "task_complete",
        "create_automation": "create_automation",
        "create_work_task": "create_work_task",
        // codeg-mcp live-feedback poll
        "check_user_feedback": "check_user_feedback",
        "mcp__codeg-mcp__check_user_feedback": "check_user_feedback",
        "mcp__codeg__check_user_feedback": "check_user_feedback",
        // OpenCode
        "patch": "apply_patch",
        "subagent": "agent",
        "delegate_task": "task",
        "call_omo_agent": "agent",
        "ast_grep_search": "grep",
        "ast_grep_replace": "edit",
        "background_task": "task",
        "background_cancel": "task",
        "background_output": "task",
        "slashcommand": "skill",
        "question": "question",
        "ask_user_question": "question",
        "askuserquestion": "question",
        "ask_question": "question",
        "mcp__codeg-mcp__ask_user_question": "question",
        "lsp_diagnostics": "lsp",
        "lsp_document_symbols": "lsp",
        "lsp_goto_definition": "lsp",
        "lsp_servers": "lsp",
        "execute": "bash",
        "search": "grep",
        "fetch": "webfetch",
        "think": "task",
        "switch_mode": "switch_mode",
        "other": "tool",
    ]

    // MARK: - normalizeToolName

    /// Collapse a raw tool name (or a live title) to the canonical name the
    /// renderers dispatch on. An unrecognised name comes back trimmed (outer
    /// quotes / colons stripped), case intact; an empty one as `"tool"`.
    ///
    /// Memoized: the same few names pass through here on every token of a
    /// streaming turn, and each pass is a run of regular expressions. Short
    /// names only — a live call's title can hold a whole command.
    static func normalizeToolName(_ toolName: String) -> String {
        let key = Array(toolName.utf16)
        if key.count > normalizedNameMaxLength { return normalizeUncached(toolName) }
        if let cached = nameCache.withLock({ $0.get(key) }) { return cached }
        let name = normalizeUncached(toolName)
        nameCache.withLock { $0.set(key, name) }
        return name
    }

    private static let normalizedNamesMax = 512
    private static let normalizedNameMaxLength = 160

    /// Insertion-ordered, evict-oldest — the web's `Map` cache. Keyed by UTF-16
    /// code units: Swift `String` equality is canonical equivalence, and two
    /// differently-composed names must not share an entry (the unmatched name is
    /// returned verbatim).
    private struct NameCache: Sendable {
        var values: [[UInt16]: String] = [:]
        var order: [[UInt16]] = []

        func get(_ key: [UInt16]) -> String? { values[key] }

        mutating func set(_ key: [UInt16], _ value: String) {
            if values[key] == nil {
                if values.count >= ToolNameNormalizer.normalizedNamesMax, !order.isEmpty {
                    values.removeValue(forKey: order.removeFirst())
                }
                order.append(key)
            }
            values[key] = value
        }
    }

    private static let nameCache = OSAllocatedUnfairLock(initialState: NameCache())

    private static func normalizeUncached(_ toolName: String) -> String {
        let raw = jsTrim(toolName)
        let trimmed = replace(replace(raw, leadingDecorRE, ""), trailingDecorRE, "")
        if trimmed.isEmpty { return "tool" }

        if let exact = exactToolNameAliases[jsLower(trimmed)] { return exact }

        if let goalUpdate = parseGoalUpdateTitle(trimmed) { return goalUpdate.toolName }

        // codex-acp command actions carry no tool name and no input — only a
        // human title — so the search / list-files identity is read back out of
        // it. Matched against `raw`: these titles END in the quote that closes
        // the query/path, which the trailing-quote strip above would eat.
        if parseCodexSearchTitle(raw) != nil { return "grep" }
        if parseCodexListFilesTitle(raw) != nil { return "glob" }

        let canonical = canonicalizeToolName(trimmed)
        if let alias = exactToolNameAliases[canonical] { return alias }

        // codeg-mcp companions. Server prefix AND separator both vary by host
        // (`mcp__<server>__<tool>`, `<server>/<tool>`, `.`, `:`), so match the bare
        // tool name after any non-alphanumeric separator. The freeform matcher
        // below deliberately does NOT catch the underscore `ask_user_question`.
        for (re, name) in suffixRules where matches(re, canonical) { return name }

        if let freeform = inferFromFreeformName(trimmed) { return freeform }

        if let liveTitleToolName = extractToolNameFromLiveCallTitle(trimmed) {
            let fromLiveTitle = normalizeToolName(liveTitleToolName)
            if fromLiveTitle != "tool" { return fromLiveTitle }
        }

        return trimmed
    }

    private static let suffixRules: [(NSRegularExpression, String)] = [
        "delegate_to_agent", "get_delegation_status", "cancel_delegation", "resume_delegation",
        "create_goal", "update_goal",
        "get_session_info", "task_progress", "task_complete", "create_automation", "create_work_task",
        "ask_user_question", "check_user_feedback",
    ].map { tool in
        (regex("[^a-z0-9]" + tool + #"\z"#), tool == "ask_user_question" ? "question" : tool)
    }

    private static func canonicalizeToolName(_ input: String) -> String {
        replace(replace(jsLower(jsTrim(input)), parensDotRE, "_"), spaceDashRunRE, "_")
    }

    // MARK: - Freeform names

    private static let freeformRules: [(NSRegularExpression, String)] = [
        (regex(#"\#(B)(?:shell|bash|exec(?:ute)?)\#(S)*[_-]?(?:command|cmd)?\#(B)"#), "bash"),
        (regex(#"apply\#(S)*[_-]?patch"#), "apply_patch"),
        (regex(#"^change(?:\z|[\#(wsClass):/_-])"#), "edit"),
        (regex(#"^read(?:\z|[\#(wsClass):/-])"#), "read"),
        (regex(#"^edit(?:\z|[\#(wsClass):/-])"#), "edit"),
        (regex(#"^write(?:\z|[\#(wsClass):/-])"#), "write"),
        (prefixWordRule("grep"), "grep"),
        (prefixWordRule("glob"), "glob"),
        (prefixWordRule("webfetch"), "webfetch"),
        (prefixWordRule("websearch"), "websearch"),
        (regex(#"\#(B)web[_\#(wsClass)-]?search\#(B)"#), "websearch"),
        (regex(#"\#(B)grep\#(B)"#), "grep"),
        (regex(#"\#(B)agent\#(B)"#), "agent"),
        (regex(#"\#(B)lsp\#(B)"#), "lsp"),
        (prefixWordRule("todowrite"), "todowrite"),
        (prefixWordRule("taskupdate"), "taskupdate"),
        (prefixWordRule("taskcreate"), "taskcreate"),
        (prefixWordRule("tasklist"), "tasklist"),
        (prefixWordRule("task"), "task"),
        (regex(#"\#(B)ask\#(S)*(?:user)?\#(S)*question\#(B)"#), "question"),
    ]

    /// `^<word>(?:\b|[_\s:-])`
    private static func prefixWordRule(_ word: String) -> NSRegularExpression {
        regex(#"^"# + word + #"(?:\#(B)|[_\#(wsClass):-])"#)
    }

    private static func inferFromFreeformName(_ input: String) -> String? {
        let normalized = jsLower(jsTrim(input))
        if normalized.isEmpty { return nil }
        for (re, name) in freeformRules where matches(re, normalized) { return name }
        return nil
    }

    private static let liveCallTitleRE = regex(
        #"^[:：'"`“”‘’\#(wsClass)]*([A-Za-z0-9_.-]+)(?:\#(S)*[:：])?\#(S)*[Cc][Aa][Ll][Ll][A-Za-z0-9_-]*['"`“”‘’\#(wsClass)]*\z"#
    )

    private static func extractToolNameFromLiveCallTitle(_ input: String) -> String? {
        guard let groups = firstMatchGroups(liveCallTitleRE, input) else { return nil }
        return groups[1]
    }

    // MARK: - Goal titles

    struct ParsedGoalUpdateTitle: Equatable, Sendable {
        var status: String
        var objective: String
        /// `create_goal` when the status is `active`, else `update_goal`.
        var toolName: String
    }

    private static let goalUpdateTitleRE = regex(
        #"^\#(ci("goal updated"))\#(S)*\(([^)]+)\)\#(S)*[:：]\#(S)*([\s\S]*)\z"#
    )

    /// `active`, `usage_limited`: lower-cased, space and dash runs folded to `_`.
    static func normalizeGoalStatus(_ status: String) -> String {
        replace(jsLower(jsTrim(status)), spaceDashRunRE, "_")
    }

    /// Codex's `Goal updated (<status>): <objective>` title.
    static func parseGoalUpdateTitle(_ input: String?) -> ParsedGoalUpdateTitle? {
        guard let input,
              let groups = firstMatchGroups(goalUpdateTitleRE, jsTrim(input)) else { return nil }
        let status = normalizeGoalStatus(groups[1] ?? "")
        let objective = jsTrim(groups[2] ?? "")
        if status.isEmpty || objective.isEmpty { return nil }
        return ParsedGoalUpdateTitle(
            status: status,
            objective: objective,
            toolName: normalizeGoalStatus(status) == "active" ? "create_goal" : "update_goal"
        )
    }

    // MARK: - Codex command-action titles (`codex-command-action.ts`)

    /// A codex-acp search command action, read back out of its title.
    struct CodexSearchAction: Equatable, Sendable {
        var query: String?
        var path: String?
    }

    private static let searchForPrefix = "Search for '"
    /// Matched from the right: a path never contains `' in `, but a query may.
    private static let queryPathSeparator = "' in "
    private static let searchInRE = regex(#"^Search in '([\s\S]*)'\z"#)
    private static let listFilesInRE = regex(#"^List files in '([\s\S]*)'\z"#)

    /// `Search for '<query>' in <path>` / `Search for '<query>'` /
    /// `Search in '<path>'` / `Search`. A bare "Search" is a successful parse
    /// with both fields nil.
    static func parseCodexSearchTitle(_ title: String?) -> CodexSearchAction? {
        guard let title else { return nil }
        let trimmed = jsTrim(title)
        if trimmed.isEmpty { return nil }
        if trimmed == "Search" { return CodexSearchAction(query: nil, path: nil) }

        if trimmed.utf16.starts(with: searchForPrefix.utf16) {
            let rest = (trimmed as NSString).substring(from: searchForPrefix.utf16.count) as NSString
            let separator = rest.range(of: queryPathSeparator, options: [.literal, .backwards]).location
            if separator != NSNotFound, separator > 0 {
                let query = rest.substring(to: separator)
                let path = jsTrim(rest.substring(from: separator + (queryPathSeparator as NSString).length))
                if !path.isEmpty { return CodexSearchAction(query: query, path: path) }
            }
            if rest.length > 0, rest.character(at: rest.length - 1) == 0x27 /* ' */ {
                let query = rest.substring(to: rest.length - 1)
                if !query.isEmpty { return CodexSearchAction(query: query, path: nil) }
            }
            return nil
        }

        if let groups = firstMatchGroups(searchInRE, trimmed), let path = groups[1], !path.isEmpty {
            return CodexSearchAction(query: nil, path: path)
        }
        return nil
    }

    /// `List files in '<path>'` / `List files`. A bare "List files" parses to
    /// `.some(nil)`.
    static func parseCodexListFilesTitle(_ title: String?) -> String?? {
        guard let title else { return nil }
        let trimmed = jsTrim(title)
        if trimmed.isEmpty { return nil }
        if trimmed == "List files" { return .some(nil) }
        if let groups = firstMatchGroups(listFilesInRE, trimmed), let path = groups[1], !path.isEmpty {
            return .some(path)
        }
        return nil
    }

    // MARK: - Input shapes

    /// A codex collab tool call (codex-acp 1.0.1 #223): its input carries
    /// inter-agent fields no other tool emits (`collab-tool.ts`).
    static func isCodexCollabInput(_ rawInput: String?) -> Bool {
        guard let parsed = tryParseInputObject(rawInput) else { return false }
        return parsed["senderThreadId"] != nil
            && parsed["receiverThreadIds"] != nil
            && parsed["agentsStates"] != nil
    }

    private static func tryParseInputObject(_ rawInput: String?) -> [String: Any]? {
        guard let rawInput, !rawInput.isEmpty else { return nil }
        return ActivityJSON.tryParse(rawInput)
    }

    /// A frame of OpenCode's code-mode tool: titled `execute`, with a `{code}`
    /// script for input.
    private static func isCodeModeExecuteFrame(title: String?, rawInput: String?) -> Bool {
        if jsLower(jsTrim(title ?? "")) != codeModeToolTitle { return false }
        guard let rawInput, !rawInput.isEmpty, jsIncludes(rawInput, #""code""#) else { return false }
        return tryParseInputObject(rawInput)?["code"] is String
    }

    private static func hasAnyKey(_ obj: [String: Any], _ keys: [String]) -> Bool {
        keys.contains { key in
            guard let value = obj[key] else { return false }
            return !(value is NSNull)
        }
    }

    private static let codexWebSearchTitleRE = regex(
        #"^(?:\#(ci("web"))\#(S)+\#(ci("search"))|\#(ci("open"))\#(S)+\#(ci("page"))|\#(ci("find"))\#(S)+\#(ci("in"))\#(S)+\#(ci("page")))(?:\#(S)*:|\#(S)|\z)"#
    )

    /// Codex ACP uses human titles for web-search follow-up actions, which keep
    /// `kind: "search"` (the same kind local fuzzy-file search uses), so the title
    /// is the only identity signal when replay omits the raw-input type.
    private static func isCodexWebSearchTitle(_ input: String?) -> Bool {
        guard let input else { return false }
        let title = jsTrim(input)
        if title.isEmpty { return false }
        return matches(codexWebSearchTitleRE, title)
    }

    private static let geminiWebSearchTitleRE = regex(
        #"^\#(ci("searching"))\#(S)+\#(ci("the"))\#(S)+\#(ci("web"))\#(S)+\#(ci("for"))\#(S)*:"#
    )

    /// Gemini's `google_web_search` reports `kind: "search"` — the kind it also
    /// uses for glob and grep — so its `Searching the web for: "<query>"` title
    /// is the only "web" signal. Anchored at the start.
    private static func isGeminiWebSearchTitle(_ input: String?) -> Bool {
        guard let input else { return false }
        let title = jsTrim(input)
        if title.isEmpty { return false }
        return matches(geminiWebSearchTitleRE, title)
    }

    /// Codex's raw-input marker is camelCase on the ACP wire (`webSearch`).
    private static func isCodexWebSearchType(_ input: Any?) -> Bool {
        guard let input = input as? String else { return false }
        return canonicalizeToolName(input).replacingOccurrences(of: "_", with: "") == "websearch"
    }

    private static func inferFromInput(rawInput: String?, kind: String?, title: String?) -> String? {
        guard let rawInput, !rawInput.isEmpty else { return nil }

        let normalizedKind = normalizeToolName(kind ?? "")
        let normalizedTitle = normalizeToolName(title ?? "")

        if jsIncludes(rawInput, "*** Begin Patch") { return "apply_patch" }

        let trimmed = jsTrim(rawInput)
        let first = trimmed.utf16.first
        if first != nil, first != 0x7B /* { */, first != 0x5B /* [ */,
           normalizedKind == "bash" || normalizedKind == "exec_command" || normalizedKind == "tool"
            || normalizedTitle == "bash" || normalizedTitle == "exec_command" {
            return "bash"
        }

        guard let parsed = tryParseInputObject(rawInput) else { return nil }

        // Cursor live MCP calls (`mcpToolCall`): resolve to `<provider>__<tool>`,
        // the shape the history parser emits — before the `args` key below
        // misreads the payload as a terminal command.
        if let mcpProvider = parsed["providerIdentifier"] as? String,
           let mcpTool = parsed["toolName"] as? String, !mcpTool.isEmpty {
            return normalizeToolName(mcpProvider.isEmpty ? mcpTool : "\(mcpProvider)__\(mcpTool)")
        }

        // `command_line` / `CommandLine`: Antigravity's exec tools, whose live
        // title IS the command — the input shape is the only signal.
        if hasAnyKey(parsed, ["command", "cmd", "script", "args", "argv", "command_args",
                              "command_line", "CommandLine"]) {
            return "bash"
        }
        // OpenCode's camelCase spellings reach the live stream verbatim.
        if hasAnyKey(parsed, ["old_string", "new_string", "replace_all",
                              "oldString", "newString", "replaceAll"]) {
            return "edit"
        }
        if hasAnyKey(parsed, ["changes"]) { return "edit" }
        if hasAnyKey(parsed, ["todos"]) { return "todowrite" }
        // `query` is a common MCP argument, not a web-search discriminator — only
        // a web search when the wire names one. Codex's generic `kind: "search"`
        // stays a local file search (`grep`).
        if hasAnyKey(parsed, ["query"]),
           normalizedTitle == "websearch" || normalizedTitle == "web_search"
            || normalizedKind == "websearch" || normalizedKind == "web_search"
            || isCodexWebSearchTitle(title) || isGeminiWebSearchTitle(title)
            || isCodexWebSearchType(parsed["type"]) {
            return "websearch"
        }
        if hasAnyKey(parsed, ["url"]) { return "webfetch" }

        let hasPattern = hasAnyKey(parsed, ["pattern"])
        let hasGlob = hasAnyKey(parsed, ["glob"])
        if hasPattern { return hasGlob ? "glob" : "grep" }
        if hasGlob { return "glob" }

        // `question`: Cline/Codex follow-ups; `questions`: codeg-mcp `ask_user_question`.
        if hasAnyKey(parsed, ["question", "questions"]) { return "question" }

        // `subagent_type`: Claude Code's Task; `subagentType`: Cursor's task tool.
        if hasAnyKey(parsed, ["subagent_type", "subagentType"]) { return "agent" }
        if hasAnyKey(parsed, ["taskId", "task_id", "subject"]) { return "task" }

        // Cursor stamps the semantic identity in `_toolName` for calls whose args
        // may not have streamed yet. `task` is its sub-agent tool; other values
        // (`createPlan`, …) collapse camelCase → snake_case.
        if let hinted = parsed["_toolName"] as? String, !hinted.isEmpty {
            if hinted == "task" { return "agent" }
            return normalizeToolName(jsLower(replace(hinted, camelBoundaryRE, "$1_$2")))
        }

        // `filePath` is OpenCode's spelling.
        if hasAnyKey(parsed, ["file_path", "notebook_path", "path", "filePath"]) {
            // Write-specific keys outrank kind/title: ACP's `edit` kind covers both
            // Edit and Write, and a Write rendered as an Edit shows nothing.
            if hasAnyKey(parsed, ["content", "new_source", "cell_type", "edit_mode"]) { return "write" }
            if ["read", "edit", "write", "delete", "move"].contains(normalizedKind) { return normalizedKind }
            if ["read", "edit", "write"].contains(normalizedTitle) { return normalizedTitle }
            return "read"
        }

        return nil
    }

    // MARK: - aliasToolInputKeys

    /// Wire spellings of the canonical (snake_case) argument names every card
    /// reads. OpenCode forwards camelCase verbatim on the LIVE stream, where the
    /// history parser has already rewritten them; `include` → `glob` is the same
    /// one-sided rename it applies to OpenCode's grep filter.
    private static let toolInputKeyAliases: [(alias: String, canonical: String)] = [
        ("filePath", "file_path"),
        ("notebookPath", "notebook_path"),
        ("oldString", "old_string"),
        ("newString", "new_string"),
        ("newSource", "new_source"),
        ("replaceAll", "replace_all"),
        ("editMode", "edit_mode"),
        ("cellType", "cell_type"),
        ("include", "glob"),
    ]

    /// Fill in canonical argument names an agent spelled differently on the wire.
    /// Only writes a canonical key that is absent (or null), so it never overrides
    /// what an agent sent — a no-op on every Rust-normalized payload (all history)
    /// and every snake_case agent; returns the input unchanged then.
    static func aliasToolInputKeys(_ parsed: [String: Any]?) -> [String: Any]? {
        guard let parsed else { return nil }
        var out: [String: Any]?
        for (alias, canonical) in toolInputKeyAliases {
            guard let value = parsed[alias], !(value is NSNull) else { continue }
            if let existing = parsed[canonical], !(existing is NSNull) { continue }
            if out == nil { out = parsed }
            out?[canonical] = value
        }
        return out ?? parsed
    }

    // MARK: - inferLiveToolName

    /// codeg-mcp delegation companions: their identity must win over input-shape
    /// heuristics (`resume_delegation` / `cancel_delegation`'s `{task_id}` would
    /// otherwise read as the generic "task" tool).
    private static let delegationCompanionTools: Set<String> = [
        "delegate_to_agent", "get_delegation_status", "cancel_delegation", "resume_delegation",
    ]

    /// Built-in tools whose meta name outranks their input shape: Claude Code's
    /// `Monitor` input carries `command`; `SandboxNetworkAccess`'s `{host}` must
    /// never be read as another tool.
    private static let metaNamedTools: Set<String> = ["monitor", "sandboxnetworkaccess"]

    /// The canonical tool name a LIVE tool call is drawn as, from its ACP title,
    /// kind, streamed input and `_meta`. The order of the rules is the contract —
    /// each one's position is load-bearing (see the web for the full history):
    ///
    /// 1. `title == "agent"` (literal) — the backend's authoritative sub-agent sentinel.
    /// 2. Grok plan-mode `x.ai/tool.kind` — its title mutates across the lifecycle.
    /// 3. codex collab input shape.
    /// 4. delegation companions / meta-named tools from `claudeCode` / `qoder` meta names.
    /// 5. the broker's `codeg.delegation` marker — the only identity on hosts that
    ///    lose the MCP name (Cursor's "MCP: tool").
    /// 6. delegation companions from the title (Grok's unwrapped `use_tool`).
    /// 7. `claudeCode.subagent: true` — classifies on frame 1, before input streams.
    /// 8. OpenCode / Kiro stamped names — their input shapes are ambiguous.
    /// 9. OpenCode code-mode `execute {code}` — a script can quote anything.
    /// 10. input shape.
    /// 11. `claudeCode.toolName`, lower-cased but NOT normalized (the live-title
    ///     heuristic would turn `memory_recall` into `memory_re`).
    /// 12. Grok `x.ai/tool.name`; 13. Qoder `qoder.toolName` (lower-cased).
    /// 14. codex plan-review marker — above the title, which is a question.
    /// 15. title, then kind, then `"tool"`.
    static func inferLiveToolName(title: String? = nil, kind: String? = nil,
                                  rawInput: String? = nil, meta: AnyJSON? = nil) -> String {
        if jsLower(jsTrim(title ?? "")) == "agent" { return "agent" }

        if let grokPlanMode = extractGrokPlanModeToolName(meta) { return grokPlanMode }

        if isCodexCollabInput(rawInput) { return collabAgentToolName }

        let metaToolName = extractClaudeCodeToolName(meta)
        let qoderToolName = extractQoderToolName(meta)
        for candidate in [metaToolName, qoderToolName] {
            guard let candidate else { continue }
            let normalizedMeta = normalizeToolName(candidate)
            if delegationCompanionTools.contains(normalizedMeta) { return normalizedMeta }
            if metaNamedTools.contains(normalizedMeta) { return normalizedMeta }
        }

        if meta?.object?["codeg.delegation"] != nil { return "delegate_to_agent" }

        let titleCompanion = normalizeToolName(title ?? "")
        if delegationCompanionTools.contains(titleCompanion) { return titleCompanion }

        if claudeCodeMarksSubagent(meta) { return "agent" }

        if let openCodeToolName = extractOpenCodeToolName(meta) {
            return normalizeToolName(openCodeToolName)
        }

        if let kiroToolName = extractKiroToolName(meta) { return normalizeToolName(kiroToolName) }

        if isCodeModeExecuteFrame(title: title, rawInput: rawInput) {
            return normalizeToolName(codeModeToolTitle)
        }

        if let byInput = inferFromInput(rawInput: rawInput, kind: kind, title: title) { return byInput }

        if let metaToolName { return jsLower(metaToolName) }

        if let grokToolName = extractGrokToolName(meta) { return normalizeToolName(grokToolName) }

        if let qoderToolName { return jsLower(normalizeToolName(qoderToolName)) }

        if codexMarksPlanReview(meta) { return "plan_review" }

        let byTitle = normalizeToolName(title ?? "")
        if byTitle != "tool" { return byTitle }

        let byKind = normalizeToolName(kind ?? "")
        if byKind != "tool" { return byKind }

        return "tool"
    }

    // MARK: - Meta readers

    /// Whether `_meta` itself names the call a `delegate_to_agent` — the
    /// broker's `codeg.delegation` stamp, or the host's own tool name
    /// (`claudeCode.toolName` / `qoder.toolName`). The identity a live call's
    /// title cannot give: a title quotes anything (`rg 'delegate_to_agent'`).
    static func metaNamesDelegation(_ meta: AnyJSON?) -> Bool {
        if meta?.object?["codeg.delegation"] != nil { return true }
        return [extractClaudeCodeToolName(meta), extractQoderToolName(meta)].contains { name in
            name.map { ActivityToolFacts.isDelegateToAgentToolName(normalizeToolName($0)) } ?? false
        }
    }

    /// `meta.<namespace>.<field>` as a trimmed, non-empty string.
    private static func metaString(_ meta: AnyJSON?, _ namespace: String, _ field: String) -> String? {
        guard let value = meta?.object?[namespace]?.object?[field]?.string else { return nil }
        let trimmed = jsTrim(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Claude Code's own name for a tool call, `_meta.claudeCode.toolName`
    /// (claude-agent-acp sets it on every live call).
    static func extractClaudeCodeToolName(_ meta: AnyJSON?) -> String? {
        metaString(meta, "claudeCode", "toolName")
    }

    /// Qoder's raw SDK name, `_meta.qoder.toolName` — on the opening `tool_call`
    /// only, and unlike `title` never rewritten into a human sentence.
    private static func extractQoderToolName(_ meta: AnyJSON?) -> String? {
        metaString(meta, "qoder", "toolName")
    }

    /// OpenCode's raw tool id, `_meta.opencode.toolName`, which the backend lifts
    /// off the opening frame (the only one that states it).
    private static func extractOpenCodeToolName(_ meta: AnyJSON?) -> String? {
        metaString(meta, "opencode", "toolName")
    }

    /// The canonical name the backend stamps beside Kiro's own,
    /// `_meta.kiro.canonicalToolName`.
    private static func extractKiroToolName(_ meta: AnyJSON?) -> String? {
        metaString(meta, "kiro", "canonicalToolName")
    }

    /// claude-agent-acp ≥0.63's subagent-launch marker,
    /// `_meta.claudeCode.subagent`. Strictly `true`.
    static func claudeCodeMarksSubagent(_ meta: AnyJSON?) -> Bool {
        meta?.object?["claudeCode"]?.object?["subagent"]?.bool == true
    }

    /// codex-acp ≥1.1.8's Plan-mode review gate, `_meta.codex.kind == "plan_review"` —
    /// the only identity the seeded call has (no input, a question for a title).
    static func codexMarksPlanReview(_ meta: AnyJSON?) -> Bool {
        meta?.object?["codex"]?.object?["kind"]?.string == "plan_review"
    }

    /// claude-agent-acp ≥0.63's display label, `_meta.claudeCode.title` (for Bash:
    /// the model-authored description) — available from frame 1, while the ACP
    /// `title` stays the raw command.
    static func extractClaudeCodeMetaTitle(_ meta: AnyJSON?) -> String? {
        metaString(meta, "claudeCode", "title")
    }

    /// claude-agent-acp ≥0.67's skill name, `_meta.claudeCode.skill` — the
    /// authoritative skill title source, present before input streams and immune
    /// to a truncated input.
    static func extractClaudeCodeSkillName(_ meta: AnyJSON?) -> String? {
        metaString(meta, "claudeCode", "skill")
    }

    /// Whether the agent moved this call's process into the background — JetBrains
    /// AIR's `_meta.jetbrains.air.asyncTasks.backgrounded` (codex-acp 1.10+). It
    /// arrives on an otherwise empty `tool_call_update`; without it the still
    /// `in_progress` launcher looks like a hung command. No `version` gate (this
    /// block has none) and strictly `true`.
    static func toolCallMovedToBackground(_ meta: AnyJSON?) -> Bool {
        meta?.object?["jetbrains"]?.object?["air"]?.object?["asyncTasks"]?.object?["backgrounded"]?.bool == true
    }

    /// Grok's plan-mode tools, keyed on the stable `_meta["x.ai/tool"].kind`
    /// (`enter_plan` / `exit_plan`); nil for every other tool.
    private static func extractGrokPlanModeToolName(_ meta: AnyJSON?) -> String? {
        switch meta?.object?["x.ai/tool"]?.object?["kind"]?.string {
        case "enter_plan": return "enter_plan_mode"
        case "exit_plan": return "exit_plan_mode"
        default: return nil
        }
    }

    /// Grok's `_meta["x.ai/tool"].name` — the one live identity that does not
    /// mutate. `use_tool` (its generic MCP envelope) is excluded: the backend puts
    /// the inner `<server>__<tool>` name in the title instead.
    private static func extractGrokToolName(_ meta: AnyJSON?) -> String? {
        guard let name = metaString(meta, "x.ai/tool", "name"), name != "use_tool" else { return nil }
        return name
    }

    // MARK: - JavaScript string semantics

    /// The contents of a character class matching JS `\s` (WhiteSpace +
    /// LineTerminator) — ICU's `\s` differs (it lacks U+000B / U+FEFF).
    private static let wsClass = #"\t\n\u000B\f\r \u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"#
    /// JS `\s`.
    private static let S = "[\(wsClass)]"
    /// JS (non-unicode) `\b`: an ASCII word boundary. ICU's `\b` is Unicode-aware.
    private static let B = #"(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"#

    /// JS `/x/i` for an ASCII literal: each letter as `[Xx]`. ICU's
    /// case-insensitivity folds non-ASCII letters (Kelvin sign, long s) onto
    /// ASCII ones, which JS's non-unicode mode does not.
    private static func ci(_ literal: String) -> String {
        literal.map { c -> String in
            guard c.isASCII, c.isLetter else { return String(c) }
            return "[\(c.uppercased())\(c.lowercased())]"
        }.joined()
    }

    private static let leadingDecorRE = regex(#"^[:：'"`“”‘’\#(wsClass)]+"#)
    private static let trailingDecorRE = regex(#"['"`“”‘’\#(wsClass)]+\z"#)
    private static let parensDotRE = regex(#"[().]"#)
    private static let spaceDashRunRE = regex(#"[\#(wsClass)-]+"#)
    private static let camelBoundaryRE = regex(#"([a-z0-9])([A-Z])"#)

    private static func isJSWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
             0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String.prototype.trim`.
    static func jsTrim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isJSWhitespace(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isJSWhitespace(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    /// `String.prototype.trimStart`.
    static func jsTrimStart(_ s: String) -> String {
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex, isJSWhitespace(scalars[start]) { start = scalars.index(after: start) }
        return String(scalars[start...])
    }

    /// `String.prototype.toLowerCase` — Foundation's mapping, which (unlike
    /// Swift's `lowercased()`) applies the final-sigma rule as JS does.
    static func jsLower(_ s: String) -> String {
        (s as NSString).lowercased
    }

    /// `String.prototype.includes` — a code-unit search, not Swift's
    /// grapheme-aware `contains`.
    private static func jsIncludes(_ haystack: String, _ needle: String) -> Bool {
        (haystack as NSString).range(of: needle, options: .literal).location != NSNotFound
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Every pattern here is a literal of this file; a failure is a typo.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Capture groups of the first match (index 0 = whole match); nil when no match.
    private static func firstMatchGroups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// `s.replace(/re/g, template)`.
    private static func replace(_ s: String, _ re: NSRegularExpression, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: template)
    }
}
