import Foundation

/// One tool call → the structured description every activity row is drawn
/// from — port of the web's `src/lib/activity/describe-tool-call.ts` (codeg
/// 0.44).
///
/// This is the single place a tool name is mapped to what the call was. It
/// reads the NORMALIZED name, so a tool can no longer get its icon from one
/// spelling and its body from another; the raw name is consulted only to
/// recognise a third-party MCP server.
enum DescribeToolCall {
    private static let planModeTools: Set<String> = ["enterplanmode", "exitplanmode", "switch_mode", "plan_review"]
    private static let todoTools: Set<String> = ["todowrite", "taskcreate", "taskupdate", "tasklist"]

    // MARK: - Kind

    /// Which row a tool call gets, before any of its payload is read.
    static func kind(_ call: ToolCallVM) -> ToolStepKind {
        if ContextCompaction.matches(call.meta) { return .compaction }
        let name = ToolNameNormalizer.normalizeToolName(call.toolName).lowercased()
        // opencode 2.x code-mode routes MCP calls through the built-in `execute`
        // tool, which normalizes to `bash` — so the name alone would call this a
        // command. The delegation call lives inside the `code` source string,
        // and on that tool the input shape outranks the name.
        if CodeModeDelegation.isCodeModeDelegationCall(normalizedToolName: name, input: call.input) {
            return call.id.isEmpty ? .generic : .delegation
        }
        // Any other code-mode script — an MCP call, or several — is a script, not a
        // command: its input is the script, which a command row would show as
        // an empty command line.
        if ActivityCodeMode.isCodeModeScriptCall(normalizedToolName: name, input: call.input) { return .script }
        switch name {
        case "agent": return .agent
        case "create_goal", "update_goal": return .goal
        case ActivityToolFacts.collabAgentToolName: return .collabAgent
        case "get_delegation_status": return .delegationStatus
        case "cancel_delegation": return .delegationCancel
        case "question": return .question
        case "check_user_feedback": return .feedback
        case "attempt_completion": return .completion
        case "bash", "exec_command": return .command
        case "monitor": return .monitor
        case "sandboxnetworkaccess": return .network
        case CodexScriptCard.toolName: return .script
        case "read", "read file": return .read
        case "grep": return .search
        case "glob", "find": return .glob
        case "ls": return .list
        case "webfetch": return .fetch
        case "websearch": return .webSearch
        case "memory_recall": return .memory
        case "edit", "write", "apply_patch", "notebookedit", "delete", "move": return .edit
        case "skill": return .skill
        default: break
        }
        if ActivityToolFacts.isDelegateToAgentToolName(name) { return call.id.isEmpty ? .generic : .delegation }
        if name == "resume_delegation" { return call.id.isEmpty ? .workbench : .delegationResume }
        if ActivityToolFacts.isCodegMcpWorkbenchTool(name) { return .workbench }
        if planModeTools.contains(name) { return .planMode }
        if todoTools.contains(name) { return .todo }
        if ShellSessionCall.isSessionToolName(name) { return .shellSession }
        if mcpIdentity(call) != nil { return .mcp }
        return .generic
    }

    /// Cline routes every MCP call through `use_mcp_tool {server_name, tool_name}`.
    private static func clineMcpIdentity(_ input: String?) -> McpIdentity? {
        guard let parsed = input.flatMap(ActivityJSON.tryParse),
              let server = parsed["server_name"] as? String, !server.isEmpty,
              let tool = parsed["tool_name"] as? String, !tool.isEmpty else { return nil }
        return McpIdentity(server: server, tool: tool)
    }

    private static func mcpIdentity(_ call: ToolCallVM) -> McpIdentity? {
        if ToolNameNormalizer.normalizeToolName(call.toolName) == "tool" { return clineMcpIdentity(call.input) }
        return ActivityMcp.parseMcpToolName(call.toolName)
    }

    // MARK: - Field access

    private struct Payload {
        let input: String?
        let output: String?
        let parsed: [String: Any]?
        /// The text `parsed` was read from — the input, or the output when the
        /// input is not a JSON object — whose key order JavaScript would keep.
        let parsedSource: String?

        func field(_ key: String) -> String? {
            if let nested = ActivityJSON.findStringFieldDeep(parsed, key: key) { return nested }
            if let input, let fromInput = ActivityJSON.extractField(input, key: key) { return fromInput }
            return nil
        }
    }

    private static func payload(_ call: ToolCallVM) -> Payload {
        if let fromInput = ToolNameNormalizer.aliasToolInputKeys(call.input.flatMap(ActivityJSON.tryParse)) {
            return Payload(input: call.input, output: call.output, parsed: fromInput, parsedSource: call.input)
        }
        let fromOutput = call.output.flatMap(ActivityJSON.tryParse)
        return Payload(input: call.input, output: call.output, parsed: fromOutput,
                       parsedSource: fromOutput == nil ? nil : call.output)
    }

    private static func filePath(_ payload: Payload) -> String? {
        for key in ["file_path", "filePath", "target_file", "targetFile", "filename", "path", "notebook_path"] {
            if let value = payload.field(key) { return value }
        }
        return nil
    }

    private static func pathTarget(_ path: String) -> ToolTarget {
        let text = ActivityFormat.shortPath(path)
        return text == path ? ToolTarget(text: text, path: path) : ToolTarget(text: text, full: path, path: path)
    }

    private static func textTarget(_ value: String, _ max: Int) -> ToolTarget {
        let clean = collapse(value)
        let text = ActivityFormat.ellipsis(clean, max)
        return text == value ? ToolTarget(text: text) : ToolTarget(text: text, full: value)
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first argument that reads as a value rather than an id, in the
    /// order the agent wrote them.
    private static func firstMeaningfulArgument(_ parsed: [String: Any]?, source: String?) -> String? {
        guard let parsed else { return nil }
        let keys = source.map { ActivityMcp.jsObjectKeys(parsed, source: $0) } ?? parsed.keys.sorted()
        for key in keys where !ActivityJSON.isLikelyIdField(key) {
            if let value = parsed[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ActivityFormat.ellipsis(collapse(value), 60)
            }
        }
        return nil
    }

    // MARK: - Describe

    /// Describe one tool call. `awaiting`: a permission request for it is open.
    static func describe(_ call: ToolCallVM, awaiting: Bool = false) -> ToolDescriptor {
        let kind = kind(call)
        let toolName = ToolNameNormalizer.normalizeToolName(call.toolName)
        let status = ActivityStatus.of(call, awaiting: awaiting)
        var base = ToolDescriptor(kind: kind, toolName: toolName, status: status)
        base.approval = ActivityApproval.approvalFromMeta(call.meta)
        let payload = payload(call)

        switch kind {
        case .command:
            return describeCommand(call, payload, base)
        case .shellSession:
            return describeShellSession(call, base)
        case .script:
            return describeScript(call, base)
        case .monitor:
            return describeMonitor(payload, base)
        case .network:
            if let host = payload.field("host") { base.target = textTarget(host, 60) }
            return base
        case .read:
            if let path = filePath(payload) { base.target = pathTarget(path) }
            base.detail = readRange(payload.parsed)
            base.notes = readNotes(payload.parsed)
            if status == .succeeded, let output = call.output, !output.isEmpty {
                base.metric = ActivityExplore.readLineCount(output).map(ToolMetric.lines)
            }
            return base
        case .search, .glob, .list:
            let pattern = payload.field("pattern") ?? payload.field("query")
            let path = payload.field("path")
            base.target = pattern.map { textTarget($0, 60) } ?? path.map(pathTarget)
            let pair = DelegationModel.outputError(call)
            let text = ActivityExplore.searchResultText(
                toolName: toolName.lowercased(), output: pair.output, errorText: pair.errorText)
            // grep's exit 1 means "found nothing", which codex reports as a
            // failed call carrying its no-match envelope (read as ""): an empty
            // result, not a failure.
            let settled: StepStatus = status == .failed && text == "" ? .succeeded : status
            if kind == .glob, pattern == nil, path != nil { base.kind = .list }
            base.status = settled
            base.detail = pattern != nil ? path.map(ActivityFormat.shortPath) : nil
            if settled == .succeeded { base.metric = searchMetric(ActivityExplore.summarizeSearchResult(text)) }
            return base
        case .fetch:
            if let url = payload.field("url") {
                base.target = textTarget(url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression), 60)
            }
            // Claude Code's WebFetch reads on past its page window from here.
            if let parsed = payload.parsed, let offset = ActivityJSON.num(parsed, "offset"), offset > 0 {
                base.notes = [.offset(Int(offset))]
            }
            return base
        case .webSearch:
            if let query = payload.field("query") { base.target = textTarget(query, 60) }
            return base
        case .memory:
            base.detail = ToolNameNormalizer.extractClaudeCodeMetaTitle(call.meta)
            return base
        case .edit:
            return describeEdit(call, base)
        case .mcp:
            return describeMcp(call, payload, base)
        case .skill:
            // OpenCode 2's skill tool takes the skill as `id`.
            let name = ToolNameNormalizer.extractClaudeCodeSkillName(call.meta)
                ?? payload.field("skill") ?? payload.field("name") ?? payload.field("id")
            base.target = name.map { ToolTarget(text: $0) }
            return base
        case .todo:
            return describeTodo(payload, base)
        case .completion:
            if let first = payload.field("result")?.components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
                base.target = textTarget(first, 80)
            }
            return base
        case .generic:
            let name = genericName(call, toolName)
            let detail = firstMeaningfulArgument(payload.parsed, source: payload.parsedSource)
                ?? ToolNameNormalizer.extractClaudeCodeMetaTitle(call.meta)
            base.target = ToolTarget(text: name)
            base.detail = detail != name ? detail : nil
            return base
        default:
            return base
        }
    }

    // MARK: - Per kind

    private static func searchMetric(_ outcome: ActivityExplore.SearchOutcome?) -> ToolMetric? {
        switch outcome {
        case .none?: return .noMatch
        case .matches(let matches, let files)?: return .matches(count: matches, files: files)
        case .files(let files)?: return .files(files)
        case .lines(let lines)?: return .results(lines)
        case nil: return nil
        }
    }

    private static func readRange(_ parsed: [String: Any]?) -> String? {
        guard let parsed else { return nil }
        let offset = ActivityJSON.num(parsed, "offset")
        let limit = ActivityJSON.num(parsed, "limit")
        if offset == nil && limit == nil { return nil }
        // OpenCode 2.2.7 reads a negative offset back from the end of the file,
        // whose line numbers the call does not name.
        if let offset, offset < 0 { return nil }
        let start = offset.map { $0 > 0 ? $0 : 1 } ?? 1
        let fmt = { (d: Double) in ActivityMcp.jsNumberString(d) }
        guard let limit else { return "L\(fmt(start))–" }
        return "L\(fmt(start))–\(fmt(start + max(limit, 1) - 1))"
    }

    /// Claude Code's Read flags worth naming: past the size limit, and the PDF
    /// pages it read.
    private static func readNotes(_ parsed: [String: Any]?) -> [ToolNote] {
        guard let parsed else { return [] }
        var notes: [ToolNote] = []
        if let pages = parsed["pages"] as? String, !pages.trimmingCharacters(in: .whitespaces).isEmpty {
            notes.append(.pages(pages.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let large = parsed["allow_large"]
        if (ActivityJSON.isBoolean(large) && (large as? Bool) == true) || (large as? String) == "true" {
            notes.append(.allowLarge)
        }
        return notes
    }

    /// The exit code the transcript kept as a field — or the live call's
    /// `_meta` carries (OpenCode 2's `metadata.exit`) — ahead of any read from
    /// the output text.
    private static func structuredExit(_ call: ToolCallVM) -> CommandExit? {
        if let code = call.exitCode { return CommandExit(code: code, signal: nil) }
        return ActivityCommand.exitFromMeta(call.meta?.foundationValue)
    }

    private static func describeCommand(_ call: ToolCallVM, _ payload: Payload, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        let display = ActivityCommand.extractDisplayCommandFromToolInput(call.input)
            ?? ActivityCommand.extractDisplayCommandFromToolInput(call.output) ?? ""
        let described = payload.field("description") ?? ToolNameNormalizer.extractClaudeCodeMetaTitle(call.meta)
        let trimmedDescription = described?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = !trimmedDescription.isEmpty
            && trimmedDescription != display.trimmingCharacters(in: .whitespacesAndNewlines)
            ? trimmedDescription : nil
        d.command = CommandInfo(
            display: display,
            lineCount: display.isEmpty ? 0 : ActivityFormat.countLines(display),
            heredoc: display.isEmpty ? nil : ActivityCommand.detectHeredoc(display),
            description: description,
            session: nil,
            durationMs: ActivityCommand.extractWallTimeMs(payload.output),
            announcedSession: base.toolName.lowercased() == "exec_command"
                ? ActivityToolFacts.announcedSessionId(payload.output) : nil)
        if let taskId = ActivityToolFacts.backgroundLaunchTaskId(payload.output) {
            d.background = .init(taskId: taskId)
        } else if ToolNameNormalizer.toolCallMovedToBackground(call.meta), base.status.isLive {
            d.background = .init(taskId: nil)
        }
        // A non-zero exit on a call that still reports success is, as a rule,
        // the program's own text, not its status; only a failure gets an exit
        // badge. The exception is an agent that reports a command's non-zero
        // exit as a SUCCESSFUL call in its own framing (OpenCode 2's closing
        // `Exited with code N`, or the code as a field on the live call's
        // `_meta`): that is the agent's status for the command.
        let reported: CommandExit?
        switch base.status {
        case .failed:
            reported = structuredExit(call) ?? ActivityCommand.extractCommandExit(payload.output)
        case .succeeded:
            reported = ActivityCommand.exitFromMeta(call.meta?.foundationValue)
                ?? ActivityCommand.extractAgentReportedExit(payload.output)
        default:
            reported = nil
        }
        var exit: CommandExit?
        if let reported, reported.code != 0 || reported.signal != nil {
            exit = CommandExit(code: reported.code,
                               signal: reported.signal ?? ActivityExitMeaning.signalOfExitCode(reported.code))
        }
        let meaning = exit.flatMap { exit in
            ActivityExitMeaning.readCommandExit(
                display, exit: exit,
                output: payload.output.map(ActivityCommand.normalizeCommandOutput) ?? "")
        }
        // An exit that answers the command's question — a search that matched
        // nothing — is no failure.
        if ActivityExitMeaning.isExitAnswer(meaning) { d.status = .succeeded }
        else if exit != nil { d.status = .failed }
        d.exit = exit
        d.exitMeaning = meaning
        return d
    }

    /// `Monitor started (task <id>, <expiry>). You will be notified …` —
    /// Claude Code 2.1.310's result for a watch that began.
    private static let monitorStarted = try! NSRegularExpression(pattern: #"^Monitor started \(task ([A-Za-z0-9_-]+)[,)]"#)

    /// Claude Code's `Monitor`: a script whose every printed line is an event,
    /// or a WebSocket whose every message is. Drawn like a command; a started
    /// one is shown by its task id.
    private static func describeMonitor(_ payload: Payload, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        let parsed = payload.parsed
        let command = (parsed?["command"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let url = command == nil ? (parsed?["ws"] as? [String: Any])?["url"] as? String : nil
        let display = command ?? url ?? ""
        let described = (parsed?["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var info = CommandInfo(
            display: display,
            lineCount: display.isEmpty ? 0 : ActivityFormat.countLines(display),
            heredoc: command.flatMap(ActivityCommand.detectHeredoc),
            description: !described.isEmpty && described != display.trimmingCharacters(in: .whitespacesAndNewlines)
                ? described : nil,
            session: nil, durationMs: nil, announcedSession: nil)
        info.websocket = url != nil
        d.command = info
        if let output = payload.output {
            let trimmed = String(output.drop(while: { $0.isWhitespace }))
            let ns = trimmed as NSString
            if let m = monitorStarted.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                d.background = .init(taskId: ns.substring(with: m.range(at: 1)))
            }
        }
        return d
    }

    private static func describeShellSession(_ call: ToolCallVM, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        let session = ShellSessionCall.parse(input: call.input)
        let name = base.toolName.lowercased()
        let display = session?.command.map(ActivityCommand.simplifyShellCommand) ?? ""
        let chars = session?.chars ?? ""
        let verb: CommandInfo.Session.Verb = !chars.isEmpty
            ? .stdin
            : (name == ShellSessionCall.waitName && session?.terminate == true ? .terminate : .wait)
        d.command = CommandInfo(
            display: display,
            lineCount: display.isEmpty ? 0 : ActivityFormat.countLines(display),
            heredoc: nil, description: nil,
            session: .init(verb: verb, sessionId: session?.sessionId, stdin: chars.isEmpty ? nil : chars),
            durationMs: ActivityCommand.extractWallTimeMs(call.output),
            announcedSession: nil)
        d.exit = base.status == .failed
            ? (structuredExit(call) ?? ActivityCommand.extractCommandExit(call.output)) : nil
        return d
    }

    private static func describeScript(_ call: ToolCallVM, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        let card = ActivityCodeMode.parseScriptCard(call.input, meta: call.meta)
        let title = card?.title.map {
            ActivityCommand.simplifyShellCommand($0).components(separatedBy: "\n").first ?? ""
        } ?? ""
        d.command = CommandInfo(
            display: title,
            lineCount: card.map { ActivityFormat.countLines($0.source) } ?? 0,
            heredoc: nil, description: nil, session: nil,
            durationMs: ActivityCommand.extractWallTimeMs(call.output),
            announcedSession: nil)
        return d
    }

    private static func describeEdit(_ call: ToolCallVM, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        let files = ActivityEdit.describeEditFiles(toolName: base.toolName.lowercased(), input: call.input, output: call.output)
        var additions = 0, deletions = 0, counted = false
        for file in files {
            if let a = file.additions { additions += a; counted = true }
            if let r = file.deletions { deletions += r; counted = true }
        }
        d.files = files
        d.target = files.count == 1 ? pathTarget(files[0].path) : nil
        if counted, !base.status.isLive, additions > 0 || deletions > 0 {
            d.metric = .diff(additions: additions, deletions: deletions)
        }
        return d
    }

    private static func describeMcp(_ call: ToolCallVM, _ payload: Payload, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        let identity = mcpIdentity(call)
        var argsSource = call.input
        if ToolNameNormalizer.normalizeToolName(call.toolName) == "tool", let parsed = payload.parsed,
           let args = parsed["arguments"], !(args is NSNull) {
            if let s = args as? String {
                argsSource = s
            } else if let raw = payload.parsedSource.flatMap({ rawTopLevelValue($0, key: "arguments") }) {
                // The arguments as the agent wrote them: `JSON.stringify` keeps
                // their key order, which a re-serialized dictionary has lost.
                argsSource = raw
            } else if JSONSerialization.isValidJSONObject([args]),
                      let data = try? JSONSerialization.data(withJSONObject: args,
                                                             options: [.fragmentsAllowed, .sortedKeys]) {
                argsSource = String(data: data, encoding: .utf8)
            }
        }
        let argument = ActivityMcp.mcpArgumentPreview(argsSource)
        let result = base.status == .succeeded
            ? ActivityMcp.mcpResultLabel(ActivityMcp.mcpResultPayload(call.output)) : nil
        let detail = [argument, result].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        d.mcp = identity
        d.target = identity.map { ToolTarget(text: $0.tool) }
        d.detail = detail.isEmpty ? nil : detail
        return d
    }

    /// The JSON text of the top-level `key`'s value in `source`, exactly as
    /// written (nil when it is not there, or does not parse on its own).
    private static func rawTopLevelValue(_ source: String, key: String) -> String? {
        let units = Array(source.utf16)
        let quote: UInt16 = 0x22, backslash: UInt16 = 0x5C
        var i = 0
        while i < units.count, units[i] != 0x7B /* { */ { i += 1 }
        guard i < units.count else { return nil }
        i += 1
        var depth = 0
        var expectKey = true
        var matched = false
        var valueStart: Int?
        func value(upTo end: Int) -> String? {
            guard let start = valueStart, start <= end else { return nil }
            let text = String(decoding: units[start..<end], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ActivityJSON.parseValue(text) == nil ? nil : text
        }
        while i < units.count {
            let c = units[i]
            if c == quote {
                let start = i + 1
                i = start
                while i < units.count, units[i] != quote { i += units[i] == backslash ? 2 : 1 }
                if depth == 0, expectKey {
                    let literal = [quote] + units[start..<min(i, units.count)] + [quote]
                    matched = (ActivityJSON.parseValue(String(decoding: literal, as: UTF16.self)) as? String) == key
                    expectKey = false
                }
                i += 1
                continue
            }
            switch c {
            case 0x3A where depth == 0 && matched && valueStart == nil: // :
                valueStart = i + 1
            case 0x7B, 0x5B: // { [
                depth += 1
            case 0x7D, 0x5D: // } ]
                if depth == 0 { return value(upTo: i) }
                depth -= 1
            case 0x2C where depth == 0: // ,
                if valueStart != nil { return value(upTo: i) }
                expectKey = true
            default:
                break
            }
            i += 1
        }
        return nil
    }

    private static func genericName(_ call: ToolCallVM, _ normalized: String) -> String {
        let lower = normalized.lowercased()
        // `tool` / `task` are catch-all normalizations; the raw name says more.
        if lower == "tool" || lower == "task" || lower == "lsp" {
            let raw = call.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? normalized : raw
        }
        return normalized
    }

    private static func describeTodo(_ payload: Payload, _ base: ToolDescriptor) -> ToolDescriptor {
        var d = base
        switch base.toolName.lowercased() {
        case "todowrite":
            if let todos = payload.parsed?["todos"] as? [Any] {
                let done = todos.filter { (($0 as? [String: Any])?["status"] as? String) == "completed" }.count
                d.detail = "\(done)/\(todos.count)"
            }
        case "taskcreate":
            if let subject = payload.field("subject") { d.target = textTarget(subject, 60) }
        case "taskupdate":
            if let id = payload.field("taskId") {
                d.target = ToolTarget(text: "#\(id)")
                d.detail = payload.field("status")
            }
        default:
            break
        }
        return d
    }
}
