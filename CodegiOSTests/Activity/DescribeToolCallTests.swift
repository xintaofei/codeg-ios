import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/describe-tool-call.test.ts` (codeg 0.44).
///
/// Web parts map onto `ToolCallVM`: `output-available` → `.done`,
/// `output-error` → `.error` with the web `errorText` as `output`,
/// `input-available` → `.running`. Inputs are written as the JSON text
/// `JSON.stringify` produces, so key order matches the web's.
@MainActor
struct DescribeToolCallTests {
    /// The web's `call(toolName, input, overrides)`.
    static func call(_ toolName: String, _ input: String?, state: ToolCallState = .done,
                     output: String? = nil, meta: String? = nil, exitCode: Int? = nil) -> ToolCallVM {
        ToolCallVM(id: "call-\(UUID().uuidString)", rawName: toolName, kind: "", state: state,
                   input: input, output: output, content: nil, isError: state == .error,
                   meta: meta.flatMap { AnyJSON.parse(jsonString: $0) }, exitCode: exitCode)
    }

    /// A web `output-error` part: iOS keeps the error text in `output`.
    static func failed(_ toolName: String, _ input: String?, errorText: String,
                       meta: String? = nil, exitCode: Int? = nil) -> ToolCallVM {
        call(toolName, input, state: .error, output: errorText, meta: meta, exitCode: exitCode)
    }

    private func describe(_ vm: ToolCallVM) -> ToolDescriptor { DescribeToolCall.describe(vm) }

    // MARK: - toolStepKind

    struct KindCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String?
        let expected: String
        init(_ name: String, _ input: String?, _ expected: String) {
            self.name = name; self.input = input; self.expected = expected
        }
        var testDescription: String { "\(name) → \(expected)" }
    }

    static let kindCases: [KindCase] = [
        // Claude Code
        .init("Read", #"{"file_path":"/r/a.ts"}"#, "read"),
        .init("Grep", #"{"pattern":"x"}"#, "search"),
        .init("Glob", #"{"pattern":"**/*.ts"}"#, "glob"),
        .init("Bash", #"{"command":"ls"}"#, "command"),
        .init("PowerShell", #"{"command":"dir"}"#, "command"),
        // A watch, not a command: never folded into "Ran N commands".
        .init("Monitor", #"{"command":"tail -f log","description":"errors"}"#, "monitor"),
        .init("SandboxNetworkAccess", #"{"host":"example.com"}"#, "network"),
        .init("Edit", #"{"file_path":"/r/a.ts","old_string":"a","new_string":"b"}"#, "edit"),
        .init("Write", #"{"file_path":"/r/a.ts","content":"x"}"#, "edit"),
        .init("NotebookEdit", #"{"notebook_path":"/r/n.ipynb"}"#, "edit"),
        .init("WebFetch", #"{"url":"https://a.dev"}"#, "fetch"),
        .init("WebSearch", #"{"query":"q"}"#, "web-search"),
        .init("Skill", #"{"skill":"pdf"}"#, "skill"),
        .init("TodoWrite", #"{"todos":[]}"#, "todo"),
        .init("Agent", #"{"prompt":"p","subagent_type":"Explore"}"#, "agent"),
        .init("Task", #"{"prompt":"p","subagent_type":"Explore"}"#, "generic"),
        .init("ExitPlanMode", ##"{"plan":"# P"}"##, "plan-mode"),
        .init("EnterPlanMode", #"{}"#, "plan-mode"),
        .init("AskUserQuestion", #"{"questions":[]}"#, "question"),
        .init("mcp__linear__get_issue", #"{"id":"HVAC-1"}"#, "mcp"),
        // codeg's own MCP companions are never third-party MCP rows
        .init("mcp__codeg-mcp__delegate_to_agent", #"{"task":"t"}"#, "delegation"),
        // opencode 2.x code-mode: the delegation call rides inside the `execute`
        // tool's `code` source string, so only the input shape can classify it.
        .init("execute",
              #"{"code":"await tools[\"codeg-mcp\"].delegate_to_agent({ agent_type: \"codex\", task: `t` })"}"#,
              "delegation"),
        // Any other code-mode `execute` is a script row: `execute` normalizes to
        // `bash`, but its input is the script, which a command row would show as
        // an empty command line.
        .init("execute", #"{"code":"return 1 + 1"}"#, "script"),
        // A `{code}` input on a real command tool stays a command.
        .init("bash", #"{"command":"node -e x","code":"x"}"#, "command"),
        // OpenCode 2's renamed tools (packages/core/src/tool/plugin, 2.2.0).
        .init("shell", #"{"command":"ls"}"#, "command"),
        .init("patch", #"{"patchText":"*** Begin Patch\n*** End Patch"}"#, "edit"),
        .init("subagent", #"{"agent":"general","description":"d","prompt":"p","subagent_type":"general"}"#, "agent"),
        .init("skill", #"{"id":"probe-skill"}"#, "skill"),
        // Another tool's `code` argument shaped like the call is no delegation.
        .init("mcp__playwright__browser_run_code",
              #"{"code":"await tools[\"codeg-mcp\"].delegate_to_agent({ agent_type: \"codex\", task: `t` })"}"#,
              "mcp"),
        .init("mcp__codeg-mcp__get_delegation_status", #"{"task_ids":[]}"#, "delegation-status"),
        .init("mcp__codeg-mcp__cancel_delegation", #"{"task_id":"t"}"#, "delegation-cancel"),
        .init("mcp__codeg-mcp__resume_delegation", #"{"task_id":"t"}"#, "delegation-resume"),
        .init("mcp__codeg-mcp__check_user_feedback", #"{}"#, "feedback"),
        .init("mcp__codeg-mcp__task_progress", #"{}"#, "workbench"),
        // codex
        // Not the web's `ls`: a saved `exec_command` codex takes for a listing
        // now reads as one (`CodexShellAction`), as it streamed.
        .init("exec_command", #"{"cmd":"make"}"#, "command"),
        .init("shell_command", #"{"command":"ls"}"#, "command"),
        .init("apply_patch", "*** Begin Patch\n*** End Patch", "edit"),
        .init("wait", #"{"cell_id":"7"}"#, "shell-session"),
        .init("write_stdin", #"{"session_id":7,"chars":""}"#, "shell-session"),
        .init("codex_script", #"{"source":"x"}"#, "script"),
        .init("view_image", #"{"path":"/r/a.png"}"#, "read"),
        .init("create_goal", #"{"objective":"o"}"#, "goal"),
        .init("linear/get_issue", #"{"id":"1"}"#, "mcp"),
        // Cline
        .init("execute_command", #"{"command":"ls"}"#, "command"),
        .init("list_files", #"{"path":"src"}"#, "glob"),
        .init("search_files", #"{"regex":"x"}"#, "search"),
        .init("attempt_completion", #"{"result":"done"}"#, "completion"),
        .init("use_mcp_tool", #"{"server_name":"gh","tool_name":"search"}"#, "mcp"),
        // pi
        .init("find", #"{"pattern":"*.ts"}"#, "glob"),
        .init("ls", #"{"path":"src"}"#, "list"),
        // Grok
        .init("run_terminal_command", #"{"command":"ls"}"#, "command"),
        // unknown
        .init("lsp_diagnostics", #"{"path":"a.ts"}"#, "generic"),
    ]

    @Test("toolStepKind %s → %s", arguments: kindCases)
    func toolStepKind(_ c: KindCase) {
        #expect(DescribeToolCall.kind(Self.call(c.name, c.input)).rawValue == c.expected)
    }

    @Test("routes a compaction marker regardless of the tool name")
    func routesACompactionMarkerRegardlessOfTheToolName() {
        #expect(DescribeToolCall.kind(Self.call("tool", nil, meta: #"{"contextCompaction":true}"#)) == .compaction)
    }

    // MARK: - exploration

    @Test("describes a read with its line count and range")
    func describesAReadWithItsLineCountAndRange() {
        let tool = describe(Self.call(
            "Read", #"{"file_path":"/repo/agent/src/q.py","offset":40,"limit":20}"#,
            output: #"{"start_line":40,"content":"a\nb\nc"}"#))
        #expect(tool.target == ToolTarget(text: "src/q.py", full: "/repo/agent/src/q.py", path: "/repo/agent/src/q.py"))
        #expect(tool.detail == "L40–59")
        #expect(tool.metric == .lines(3))
    }

    @Test("names no range for a read counted back from the end")
    func namesNoRangeForAReadCountedBackFromTheEnd() {
        // OpenCode 2.2.7: `offset: -50` is the file's last 50 lines.
        let tool = describe(Self.call(
            "read", #"{"filePath":"/repo/agent/src/q.py","offset":-50}"#,
            output: #"{"start_line":151,"content":"a\nb"}"#))
        #expect(tool.detail == nil)
    }

    @Test("does not count lines of a read still in flight")
    func doesNotCountLinesOfAReadStillInFlight() {
        let tool = describe(Self.call("Read", #"{"file_path":"/r/a.ts"}"#, state: .running))
        #expect(tool.status == .running)
        #expect(tool.metric == nil)
    }

    @Test("counts grep hits and shows the scope")
    func countsGrepHitsAndShowsTheScope() {
        let tool = describe(Self.call(
            "Grep", #"{"pattern":"source_bindings","path":"/repo/agent/src"}"#,
            output: "a.py:1:x\na.py:9:y\nb.py:3:z\nc.py:4:w"))
        #expect(tool.target?.text == "source_bindings")
        #expect(tool.detail == "agent/src")
        #expect(tool.metric == .matches(count: 4, files: 3))
    }

    @Test("reports a grep that matched nothing")
    func reportsAGrepThatMatchedNothing() {
        let tool = describe(Self.call("Grep", #"{"pattern":"zzz"}"#, output: ""))
        #expect(tool.status == .succeeded)
        #expect(tool.metric == .noMatch)
    }

    @Test("treats a pattern-less glob as a listing")
    func treatsAPatternLessGlobAsAListing() {
        let tool = describe(Self.call("list_files", #"{"path":"/repo/src"}"#, output: "a.ts\nb.ts"))
        #expect(tool.kind == .list)
        #expect(tool.metric == .files(2))
    }

    @Test("shows a fetch's URL without its scheme")
    func showsAFetchsURLWithoutItsScheme() {
        #expect(describe(Self.call("WebFetch", #"{"url":"https://react.dev/learn"}"#)).target?.text == "react.dev/learn")
    }

    // MARK: - commands

    @Test("shows the command, not Claude's description")
    func showsTheCommandNotClaudesDescription() {
        let tool = describe(Self.call("Bash", #"{"command":"pnpm --filter web test","description":"Run web unit tests"}"#))
        #expect(tool.command?.display == "pnpm --filter web test")
        #expect(tool.command?.lineCount == 1)
        #expect(tool.command?.heredoc == nil)
        #expect(tool.command?.description == "Run web unit tests")
        #expect(tool.command?.session == nil)
        #expect(tool.exit == nil)
    }

    @Test("reports a failed command's exit code")
    func reportsAFailedCommandsExitCode() {
        let tool = describe(Self.failed("Bash", #"{"command":"pnpm test"}"#, errorText: "Tests: 1 failed\n\nExit code 1"))
        #expect(tool.status == .failed)
        #expect(tool.exit == CommandExit(code: 1, signal: nil))
    }

    // OpenCode 2 completes a command that exited non-zero SUCCESSFULLY, closing
    // its result with an `Exited with code N` notice block, and the live call
    // carries the code as `_meta["codeg.exitCode"]` too.
    @Test("reads OpenCode 2's exit notice as the command's failure")
    func readsOpenCode2sExitNoticeAsTheCommandsFailure() {
        let fromText = describe(Self.call(
            "shell", #"{"command":"pnpm build"}"#,
            output: "ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL\n\nExited with code 1"))
        #expect(fromText.status == .failed)
        #expect(fromText.exit == CommandExit(code: 1, signal: nil))

        let fromMeta = describe(Self.call(
            "shell", #"{"command":"make"}"#, output: "make: *** [all] Error 2\n",
            meta: #"{"opencode":{"toolName":"shell"},"codeg.exitCode":2}"#))
        #expect(fromMeta.status == .failed)
        #expect(fromMeta.exit == CommandExit(code: 2, signal: nil))
    }

    @Test("reads a missing path the way it does for every agent")
    func readsAMissingPathTheWayItDoesForEveryAgent() {
        // The 2.2.0 capture's `ls` of a missing directory: the notice is framing,
        // so what is left is the "not found" answer, as for Claude Code's `ls`.
        let tool = describe(Self.call(
            "shell", #"{"command":"ls /definitely-not-here"}"#,
            output: "ls: /definitely-not-here: No such file or directory\n\nExited with code 1"))
        #expect(tool.status == .succeeded)
        #expect(tool.exit == CommandExit(code: 1, signal: nil))
        #expect(tool.exitMeaning == .notFound)
    }

    @Test("keeps OpenCode 2's no-match search a success")
    func keepsOpenCode2sNoMatchSearchASuccess() {
        let tool = describe(Self.call("shell", #"{"command":"rg -n 'nothing-here' src"}"#, output: "Exited with code 1"))
        #expect(tool.status == .succeeded)
        #expect(tool.exit == CommandExit(code: 1, signal: nil))
    }

    // 2.2.7 ends a command a signal killed with `Exit code: 143 (SIGTERM)` and
    // records no `exit` field for it.
    @Test("reads OpenCode 2.2.7's signal notice as the command's failure")
    func readsOpenCode227sSignalNoticeAsTheCommandsFailure() {
        let tool = describe(Self.call("shell", #"{"command":"./serve.sh"}"#,
                                      output: "listening on :3000\n\nExit code: 143 (SIGTERM)"))
        #expect(tool.status == .failed)
        #expect(tool.exit == CommandExit(code: nil, signal: "SIGTERM"))
    }

    @Test("leaves a succeeded command's own text alone")
    func leavesASucceededCommandsOwnTextAlone() {
        // The program printed the words, mid-output: not the agent's notice.
        let tool = describe(Self.call("shell", #"{"command":"./report.sh"}"#, output: "Exited with code 3\nall checks passed"))
        #expect(tool.status == .succeeded)
        #expect(tool.exit == nil)
    }

    @Test("prefers the exit code the transcript kept as a field")
    func prefersTheExitCodeTheTranscriptKeptAsAField() {
        let tool = describe(Self.failed("bash", #"{"command":"make"}"#, errorText: "boom\n\nExit code 1", exitCode: 2))
        #expect(tool.exit == CommandExit(code: 2, signal: nil))
    }

    @Test("settles a search that matched nothing as done, saying so")
    func settlesASearchThatMatchedNothingAsDoneSayingSo() {
        // Claude Code: the failure is the bare `Exit code 1`.
        let claude = describe(Self.failed("Bash", #"{"command":"rg -n 'source_bindings' src"}"#, errorText: "Exit code 1"))
        #expect(claude.status == .succeeded)
        #expect(claude.exitMeaning == .noMatch)
        #expect(claude.exit == CommandExit(code: 1, signal: nil))
        // claude-agent-acp fences it for a client without a terminal channel.
        #expect(describe(Self.failed("Bash", #"{"command":"grep -rn TODO src"}"#,
                                     errorText: "```\nExit code 1\n```")).exitMeaning == .noMatch)
        // codex: its framing, the code kept as a field.
        let codex = describe(Self.failed(
            "exec_command", #"{"cmd":"/bin/zsh -lc \"test -f package.json\""}"#,
            errorText: "Chunk ID: 1a2b\nWall time: 0.0100 seconds\nProcess exited with code 1\nOriginal token count: 0\nOutput:\n",
            exitCode: 1))
        #expect(codex.status == .succeeded)
        #expect(codex.exitMeaning == .false)
    }

    @Test("keeps a failure that only looks like an answer")
    func keepsAFailureThatOnlyLooksLikeAnAnswer() {
        let tool = describe(Self.failed("Bash", #"{"command":"grep -rn TODO missing-dir"}"#,
                                        errorText: "grep: missing-dir: No such file or directory\n\nExit code 2"))
        #expect(tool.status == .failed)
        #expect(tool.exitMeaning == nil)
    }

    @Test("names a failure its code stands for")
    func namesAFailureItsCodeStandsFor() {
        let notFound = describe(Self.failed("Bash", #"{"command":"pyhton x.py"}"#,
                                            errorText: "Exit code 127\n(eval):1: command not found: pyhton"))
        #expect(notFound.status == .failed)
        #expect(notFound.exitMeaning == .commandNotFound)
        let killed = describe(Self.failed("Bash", #"{"command":"node build.js"}"#, errorText: "Killed\n\nExit code 137"))
        #expect(killed.status == .failed)
        #expect(killed.exit == CommandExit(code: 137, signal: "SIGKILL"))
    }

    @Test("leaves the exit unknown when a failure reports none")
    func leavesTheExitUnknownWhenAFailureReportsNone() {
        #expect(describe(Self.failed("Bash", #"{"command":"x"}"#, errorText: "something broke")).exit == nil)
    }

    @Test("recognizes a heredoc script")
    func recognizesAHeredocScript() {
        let tool = describe(Self.call("Bash", #"{"command":"python - <<'PY'\nprint(1)\nprint(2)\nPY"}"#))
        #expect(tool.command?.heredoc == HeredocCommand(head: "python - <<'PY'", interpreter: "python", bodyLines: 2))
        #expect(tool.command?.lineCount == 4)
    }

    @Test("flags a background launch with its task id")
    func flagsABackgroundLaunchWithItsTaskId() {
        let tool = describe(Self.call(
            "Bash", #"{"command":"python regen.py","run_in_background":true}"#,
            output: "Command running in background with ID: beecec7d. Output is being written to: /tmp/x"))
        #expect(tool.background == ToolDescriptor.Background(taskId: "beecec7d"))
    }

    @Test("flags codex's backgrounded call while it is unsettled")
    func flagsCodexsBackgroundedCallWhileItIsUnsettled() {
        let meta = #"{"jetbrains":{"air":{"asyncTasks":{"backgrounded":true}}}}"#
        #expect(describe(Self.call("exec_command", #"{"cmd":"pnpm dev"}"#, state: .running, meta: meta)).background
            == ToolDescriptor.Background(taskId: nil))
        #expect(describe(Self.call("exec_command", #"{"cmd":"pnpm dev"}"#, meta: meta)).background == nil)
    }

    @Test("reads codex's wall time")
    func readsCodexsWallTime() {
        let tool = describe(Self.call("exec_command", #"{"cmd":"make"}"#,
                                      output: "Chunk ID: 1\nWall time: 14.2 seconds\nOutput:\nok"))
        #expect(tool.command?.durationMs == 14200)
    }

    @Test("describes codex's session tools")
    func describesCodexsSessionTools() {
        let wait = describe(Self.call("wait", #"{"cell_id":"17","session_command":"bash -lc 'pnpm dev'"}"#)).command
        #expect(wait?.display == "pnpm dev")
        #expect(wait?.session == CommandInfo.Session(verb: .wait, sessionId: "17", stdin: nil))
        #expect(describe(Self.call("write_stdin", #"{"session_id":17,"chars":"\u0003"}"#)).command?.session
            == CommandInfo.Session(verb: .stdin, sessionId: "17", stdin: "\u{0003}"))
        #expect(describe(Self.call("wait", #"{"cell_id":"17","terminate":true}"#)).command?.session?.verb == .terminate)
    }

    // MARK: - code-mode scripts

    // OpenCode 2.2.0's `execute` running an MCP tool (live capture): the script
    // is the input, the calls it made ride the `_meta`, the result is the text.
    private static let codeInput =
        #"{"code":"const r = await tools.probe.echo({ text: 'hi from code mode' });\nreturn r"}"#

    @Test("titles the row with the tools the script called")
    func titlesTheRowWithTheToolsTheScriptCalled() {
        let tool = describe(Self.call(
            "execute", Self.codeInput,
            output: "{\n  \"echoed\": \"hi from code mode\"\n}",
            meta: #"{"opencode":{"toolName":"execute"},"codeg.codeModeCalls":[{"tool":"probe.echo","status":"completed","input":{"text":"hi from code mode"}}]}"#))
        #expect(tool.kind == .script)
        #expect(tool.command?.display == "probe.echo")
        #expect(tool.command?.lineCount == 2)
    }

    @Test("titles a script whose calls are not known yet by its first line")
    func titlesAScriptWhoseCallsAreNotKnownYetByItsFirstLine() {
        let tool = describe(Self.call("execute", Self.codeInput, state: .running))
        #expect(tool.kind == .script)
        #expect(tool.command?.display == "const r = await tools.probe.echo({ text: 'hi from code mode' });")
    }

    // MARK: - Claude Code monitors and network requests

    // Claude Code 2.1.310's result for a started Monitor, verbatim.
    private static let started =
        "Monitor started (task bttyx34fg, expires in 5m unless the source ends first; you get one notice at expiry \u{2014} re-arm if you still need the watch). You will be notified on each event. Keep working \u{2014} do not poll or sleep. Events may arrive while you are waiting for the user \u{2014} an event is not their reply."

    @Test("draws a started monitor by its command, description and task")
    func drawsAStartedMonitorByItsCommandDescriptionAndTask() {
        let tool = describe(Self.call(
            "Monitor", #"{"command":"for i in 1 2 3; do echo event-$i; sleep 2; done","description":"probe monitor"}"#,
            output: Self.started))
        #expect(tool.kind == .monitor)
        #expect(tool.command?.display == "for i in 1 2 3; do echo event-$i; sleep 2; done")
        #expect(tool.command?.description == "probe monitor")
        #expect(tool.command?.lineCount == 1)
        #expect(tool.command?.websocket == false)
        #expect(tool.background == ToolDescriptor.Background(taskId: "bttyx34fg"))
    }

    @Test("reads a persistent monitor's task the same way")
    func readsAPersistentMonitorsTaskTheSameWay() {
        let tool = describe(Self.call(
            "Monitor", #"{"command":"tail -f app.log","description":"app log","persistent":true}"#,
            output: "Monitor started (task b2, persistent \u{2014} runs until TaskStop or session end). You will be notified on each event."))
        #expect(tool.background == ToolDescriptor.Background(taskId: "b2"))
    }

    @Test("names a WebSocket monitor by its URL")
    func namesAWebSocketMonitorByItsURL() {
        let tool = describe(Self.call("Monitor", #"{"description":"CI events","ws":{"url":"wss://ci.example.com/events"}}"#))
        #expect(tool.command?.display == "wss://ci.example.com/events")
        #expect(tool.command?.description == "CI events")
        #expect(tool.command?.heredoc == nil)
        #expect(tool.command?.websocket == true)
        #expect(tool.background == nil)
    }

    @Test("names no task for a monitor that did not start")
    func namesNoTaskForAMonitorThatDidNotStart() {
        let tool = describe(Self.failed(
            "Monitor", #"{"command":"tail -f log","description":"log"}"#,
            errorText: "This call was interrupted before the monitor started; nothing is running."))
        #expect(tool.status == .failed)
        #expect(tool.background == nil)
    }

    @Test("names the host a sandbox network request is for")
    func namesTheHostASandboxNetworkRequestIsFor() {
        let tool = describe(Self.call("SandboxNetworkAccess", #"{"host":"example.com"}"#))
        #expect(tool.kind == .network)
        #expect(tool.target == ToolTarget(text: "example.com"))
    }

    // MARK: - edits

    @Test("names a single file and totals its lines")
    func namesASingleFileAndTotalsItsLines() {
        let tool = describe(Self.call("Edit", #"{"file_path":"/repo/agent/q.py","old_string":"a","new_string":"b\nc\nd"}"#))
        #expect(tool.target?.path == "/repo/agent/q.py")
        #expect(tool.metric == .diff(additions: 3, deletions: 1))
    }

    @Test("hides the counts while the edit is still running")
    func hidesTheCountsWhileTheEditIsStillRunning() {
        let tool = describe(Self.call("Edit", #"{"file_path":"/r/a.ts","old_string":"a","new_string":"b"}"#, state: .running))
        #expect(tool.metric == nil)
    }

    @Test("leaves the target empty for a multi-file patch")
    func leavesTheTargetEmptyForAMultiFilePatch() {
        let patch = "*** Begin Patch\n*** Update File: a.ts\n+x\n*** Update File: b.ts\n-y\n*** End Patch"
        let tool = describe(Self.call("apply_patch", patch))
        #expect(tool.files?.count == 2)
        #expect(tool.target == nil)
        #expect(tool.metric == .diff(additions: 1, deletions: 1))
    }

    // MARK: - MCP and generic tools

    @Test("splits the server off and summarizes arguments and result")
    func splitsTheServerOffAndSummarizesArgumentsAndResult() {
        let tool = describe(Self.call(
            "mcp__linear__get_issue", #"{"id":"HVAC-212"}"#,
            output: #"{"title":"Inactive bindings leak into report","state":"In Progress"}"#))
        #expect(tool.mcp == McpIdentity(server: "linear", tool: "get_issue"))
        #expect(tool.target == ToolTarget(text: "get_issue"))
        #expect(tool.detail == "HVAC-212 · Inactive bindings leak into report")
    }

    @Test("reads Cline's use_mcp_tool envelope")
    func readsClinesUseMcpToolEnvelope() {
        let tool = describe(Self.call("use_mcp_tool", #"{"server_name":"github","tool_name":"search_code","arguments":{"q":"useMemo"}}"#))
        #expect(tool.mcp == McpIdentity(server: "github", tool: "search_code"))
        #expect(tool.detail == "useMemo")
    }

    @Test("names an unknown tool by its raw name and first argument")
    func namesAnUnknownToolByItsRawNameAndFirstArgument() {
        let tool = describe(Self.call("lsp_diagnostics", #"{"id":"1","path":"src/a.ts"}"#))
        #expect(tool.target == ToolTarget(text: "lsp_diagnostics"))
        #expect(tool.detail == "src/a.ts")
    }

    // iOS regressions (not in the web suite): key order that `JSON.stringify`
    // and `Object.entries` keep, which a parsed dictionary has lost.

    @Test("names an unknown tool by the first argument its output wrote, when its input is no JSON")
    func namesAnUnknownToolByTheFirstArgumentItsOutputWrote() {
        // Web: `parsed` falls back to the output, and `Object.entries` walks it
        // in the order it was written.
        let tool = describe(Self.call("lsp_diagnostics", "not json", output: #"{"zeta":"first","alpha":"second"}"#))
        #expect(tool.detail == "first")
    }

    @Test("previews Cline's use_mcp_tool arguments in the order they were written")
    func previewsClinesArgumentsInTheOrderTheyWereWritten() {
        let tool = describe(Self.call(
            "use_mcp_tool",
            #"{"server_name":"github","tool_name":"search_code","arguments":{"q":"useMemo","page":2,"a":"z"},"extra":1}"#))
        #expect(tool.detail == "useMemo")
        let last = describe(Self.call(
            "use_mcp_tool", #"{"server_name":"github","tool_name":"search_code","arguments": {"zz":"x","a":"y"} }"#))
        #expect(last.detail == "x")
    }

    @Test("prefers Claude's skill marker")
    func prefersClaudesSkillMarker() {
        #expect(describe(Self.call("Skill", #"{"skill":"x"}"#, meta: #"{"claudeCode":{"skill":"pdf"}}"#)).target
            == ToolTarget(text: "pdf"))
    }

    // Adapted from "caches per part object": iOS descriptors are values, so the
    // cache is checked for giving back the same description of the same call.
    @Test("caches per part object")
    func cachesPerPartObject() {
        let part = Self.call("Read", #"{"file_path":"/r/a.ts"}"#)
        #expect(DescribeCache.describe(part, awaiting: false) == DescribeCache.describe(part, awaiting: false))
        #expect(DescribeCache.describe(part, awaiting: false) == DescribeToolCall.describe(part))
    }

    // MARK: - approvals

    @Test("carries the approval a detail load stamped on the call")
    func carriesTheApprovalADetailLoadStampedOnTheCall() {
        let tool = describe(Self.call(
            "Bash", #"{"command":"git commit -am wip"}"#,
            meta: #"{"codeg.approval":{"option_kind":"allow_once","option_name":"Allow","origin":"user","decided_at":"2026-10-22T09:41:12Z"}}"#))
        #expect(tool.approval == ToolApproval(decision: .allowOnce, optionName: "Allow", origin: "user",
                                              decidedAt: "2026-10-22T09:41:12Z"))
    }

    @Test("has none when the call carries no stamp")
    func hasNoneWhenTheCallCarriesNoStamp() {
        #expect(describe(Self.call("Read", #"{"file_path":"/r/a.ts"}"#)).approval == nil)
    }
}
