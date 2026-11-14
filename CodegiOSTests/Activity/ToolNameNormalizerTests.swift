import Foundation
import Testing
@testable import Codeg

// `src/lib/tool-call-normalization.test.ts` (codeg 0.44), case for case, plus
// the `inferLiveToolName` assertions of
// `src/lib/adapters/qoder-codeg-mcp-pipeline.test.ts`. Suites map to the web's
// `describe` blocks and tests to its `it`s; inputs are the web's verbatim, with
// `JSON.stringify({...})` written out as JSON text.

private typealias N = ToolNameNormalizer

private func live(title: String? = nil, kind: String? = nil,
                  rawInput: String? = nil, meta: String? = nil) -> String {
    N.inferLiveToolName(title: title, kind: kind, rawInput: rawInput, meta: m(meta))
}

/// `_meta` from its JSON text — so `true` stays a boolean and `1` a number.
private func m(_ json: String?) -> AnyJSON? {
    guard let json else { return nil }
    return AnyJSON.parse(jsonString: json)
}

private func obj(_ json: String) -> [String: Any] {
    ActivityJSON.tryParse(json)!
}

private func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return (a as NSDictionary).isEqual(b as NSDictionary)
    default: return false
    }
}

@Suite("aliasToolInputKeys")
struct AliasToolInputKeysTests {
    @Test func fillsTheCanonicalNamesOpenCodeSpellsInCamelCase() {
        #expect(same(
            N.aliasToolInputKeys(obj(#"{"filePath":"src/app/minimal/page.tsx","content":"export const A = 1\n"}"#)),
            obj(#"{"filePath":"src/app/minimal/page.tsx","file_path":"src/app/minimal/page.tsx","content":"export const A = 1\n"}"#)
        ))

        let out = N.aliasToolInputKeys(obj(#"{"filePath":"src/app.ts","oldString":"a","newString":"b","replaceAll":true}"#))!
        #expect(out["file_path"] as? String == "src/app.ts")
        #expect(out["old_string"] as? String == "a")
        #expect(out["new_string"] as? String == "b")
        #expect(ActivityJSON.isBoolean(out["replace_all"]) && (out["replace_all"] as? Bool) == true)
    }

    @Test func neverOverridesWhatTheAgentActuallySent() {
        let input = obj(#"{"filePath":"camel.ts","file_path":"snake.ts"}"#)
        #expect(same(N.aliasToolInputKeys(input), input))
    }

    @Test func isANoOpOnAlreadyCanonicalAndUnrelatedInput() {
        let canonical = obj(#"{"file_path":"a.ts","old_string":"x","new_string":"y"}"#)
        #expect(same(N.aliasToolInputKeys(canonical), canonical))

        let unrelated = obj(#"{"command":"pnpm test"}"#)
        #expect(same(N.aliasToolInputKeys(unrelated), unrelated))

        #expect(N.aliasToolInputKeys(nil) == nil)
    }

    @Test func ignoresAnAliasWhoseValueIsNull() {
        let input = obj(#"{"filePath":null,"content":"x"}"#)
        #expect(same(N.aliasToolInputKeys(input), input))
    }
}

@Suite("inferLiveToolName on OpenCode's code-mode execute frames")
struct OpenCodeCodeModeTests {
    private func replay(_ codeJSON: String) -> String {
        live(title: "execute", kind: "other", rawInput: #"{"code":"# + codeJSON + "}")
    }

    @Test func keepsTheExecuteIdentityWhenTheScriptQuotesAPatch() {
        #expect(replay(#""await tools['codeg-mcp'].delegate_to_agent({agent_type:'codex',task:`Apply this patch:\n*** Begin Patch\n*** Add File: hello.txt\n+hello\n*** End Patch`})""#) == "bash")
        #expect(replay(#""return 1 + 1""#) == "bash")
    }

    @Test func leavesOtherToolsToTheInputHeuristics() {
        #expect(live(title: "apply_patch", rawInput: #"{"input":"*** Begin Patch\n*** End Patch"}"#) == "apply_patch")
        #expect(live(title: "browser_run_code", rawInput: #"{"code":"*** Begin Patch"}"#) == "apply_patch")
        #expect(live(title: "execute", rawInput: #"{"code":42,"input":"*** Begin Patch"}"#) == "apply_patch")
    }
}

@Suite("OpenCode 2 tool names")
struct OpenCode2ToolNameTests {
    private func opening(_ name: String) -> String {
        live(title: name, kind: "other", rawInput: "{}", meta: #"{"opencode":{"toolName":"\#(name)"}}"#)
    }

    @Test func mapsTheRenamedToolsToTheirCards() {
        #expect(N.normalizeToolName("patch") == "apply_patch")
        #expect(N.normalizeToolName("subagent") == "agent")
        #expect(N.normalizeToolName("shell") == "bash")
        #expect(opening("patch") == "apply_patch")
        #expect(opening("subagent") == "agent")
        #expect(opening("shell") == "bash")
    }

    @Test func namesASubAgentsCallFromTheStampNotItsPrefixedTitle() {
        #expect(live(
            title: "read", kind: "read", rawInput: #"{"path":"hello.txt"}"#,
            meta: #"{"opencode/child-session":{"id":"ses_child","title":"Probe child task"},"opencode":{"toolName":"read"},"\#(N.parentToolCallMetaKey)":"call_main_9_11"}"#
        ) == "read")
    }
}

@Suite("inferLiveToolName meta.claudeCode.toolName override")
struct ClaudeCodeMetaOverrideTests {
    @Test func returnsMemoryRecallForSynthesizedRecallEventsWithoutRawInput() {
        #expect(live(title: "Recalled 3 memories", kind: "read", rawInput: nil,
                     meta: #"{"claudeCode":{"toolName":"memory_recall"}}"#) == "memory_recall")
        #expect(live(title: "Recalled synthesized memory", kind: "read", rawInput: nil,
                     meta: #"{"claudeCode":{"toolName":"memory_recall"}}"#) == "memory_recall")
    }

    @Test func namesEnterPlanModeByItsMetaNameWhateverKindTheAdapterGivesIt() {
        let meta = #"{"claudeCode":{"toolName":"EnterPlanMode"}}"#
        for kind in ["switch_mode", "other"] {
            for rawInput in [nil, "{}"] as [String?] {
                let name = live(title: "EnterPlanMode", kind: kind, rawInput: rawInput, meta: meta)
                #expect(name == "enterplanmode", "\(kind) \(String(describing: rawInput))")
                #expect(N.normalizeToolName(name) == "enterplanmode")
            }
        }
        #expect(live(title: nil, kind: "switch_mode", rawInput: nil, meta: meta) == "enterplanmode")
        #expect(live(title: nil, kind: "switch_mode", rawInput: nil) == "switch_mode")
    }

    @Test func fallsBackToTitleBasedInferenceWhenNoMetaIsProvided() {
        #expect(live(title: "Recalled 3 memories", kind: "read", rawInput: nil) != "memory_recall")
    }

    @Test func resolvesDelegateToAgentFromBrokerDelegationMetaOnIdentityLessWires() {
        #expect(live(title: "MCP: tool", kind: "other", rawInput: "{}",
                     meta: #"{"codeg.delegation":{"status":"running","child_conversation_id":42}}"#) == "delegate_to_agent")
    }

    @Test func keepsInputShapePriorityForCallsWithoutDelegationMeta() {
        #expect(live(title: "MCP: tool", kind: "other", rawInput: "{}", meta: nil) != "delegate_to_agent")
    }

    @Test func returnsCanonicalLowerCaseAgentForTheSDKAgentToolBeforeRawInputStreamsIn() {
        #expect(live(title: "Explore the codebase", kind: "other", rawInput: nil,
                     meta: #"{"claudeCode":{"toolName":"Agent"}}"#) == "agent")
    }

    @Test func keepsMemoryRecallIntactWhenLowerCasingTheMetaToolNameFallback() {
        #expect(live(title: "Recalled 3 memories", kind: "read", rawInput: nil,
                     meta: #"{"claudeCode":{"toolName":"memory_recall"}}"#) == "memory_recall")
    }

    @Test func preservesSubAgentDetectionWhenRawInputCarriesSubagentType() {
        #expect(live(title: "Implement feature X", kind: "other",
                     rawInput: #"{"subagent_type":"general-purpose","prompt":"Do the thing"}"#,
                     meta: #"{"claudeCode":{"toolName":"Task"}}"#) == "agent")
    }

    @Test func classifiesViaTheAuthoritativeSubagentMarkerBeforeAnyInputShape() {
        #expect(live(title: "Implement feature X", kind: "other", rawInput: nil,
                     meta: #"{"claudeCode":{"toolName":"Task","subagent":true}}"#) == "agent")
        #expect(live(title: "Run checks", kind: "other", rawInput: #"{"command":"pnpm test"}"#,
                     meta: #"{"claudeCode":{"toolName":"Agent","subagent":true}}"#) == "agent")
        #expect(live(title: "bash", kind: "execute", rawInput: #"{"command":"ls"}"#,
                     meta: #"{"claudeCode":{"toolName":"Bash","subagent":"yes"}}"#) == "bash")
    }

    @Test func claudeCodeMarksSubagentAndExtractClaudeCodeMetaTitleGuardTheirShapes() {
        #expect(N.claudeCodeMarksSubagent(m(#"{"claudeCode":{"subagent":true}}"#)) == true)
        #expect(N.claudeCodeMarksSubagent(m(#"{"claudeCode":{"subagent":false}}"#)) == false)
        #expect(N.claudeCodeMarksSubagent(m(#"{"claudeCode":{}}"#)) == false)
        #expect(N.claudeCodeMarksSubagent(nil) == false)
        #expect(N.claudeCodeMarksSubagent(m(#"{"claudeCode":"subagent"}"#)) == false)

        #expect(N.extractClaudeCodeMetaTitle(m(#"{"claudeCode":{"title":"Show current diff"}}"#)) == "Show current diff")
        #expect(N.extractClaudeCodeMetaTitle(m(#"{"claudeCode":{"title":"   "}}"#)) == nil)
        #expect(N.extractClaudeCodeMetaTitle(m(#"{"claudeCode":{"title":42}}"#)) == nil)
        #expect(N.extractClaudeCodeMetaTitle(m(#"{"claudeCode":{}}"#)) == nil)
        #expect(N.extractClaudeCodeMetaTitle(nil) == nil)
    }

    @Test func extractClaudeCodeSkillNameReadsThe986SkillMetaAndGuardsItsShape() {
        #expect(N.extractClaudeCodeSkillName(m(#"{"claudeCode":{"toolName":"Skill","skill":"commit-helper","skillPath":"/repo/.claude/skills/commit-helper/SKILL.md"}}"#)) == "commit-helper")
        #expect(N.extractClaudeCodeSkillName(m(#"{"claudeCode":{"skill":"  "}}"#)) == nil)
        #expect(N.extractClaudeCodeSkillName(m(#"{"claudeCode":{"skill":7}}"#)) == nil)
        #expect(N.extractClaudeCodeSkillName(m(#"{"claudeCode":{}}"#)) == nil)
        #expect(N.extractClaudeCodeSkillName(m(#"{"skill":"top-level"}"#)) == nil)
        #expect(N.extractClaudeCodeSkillName(nil) == nil)
    }

    @Test func resolvesDelegationCompanionToolsFromMetaOverTheInputShapeHeuristic() {
        #expect(live(title: "mcp__codeg-delegate__get_delegation_status", kind: "other",
                     rawInput: #"{"task_ids":["t1"],"wait_ms":1000}"#,
                     meta: #"{"claudeCode":{"toolName":"mcp__codeg-delegate__get_delegation_status"}}"#) == "get_delegation_status")
        #expect(live(title: "mcp__codeg-delegate__cancel_delegation", kind: "other",
                     rawInput: #"{"task_id":"t1"}"#,
                     meta: #"{"claudeCode":{"toolName":"mcp__codeg-delegate__cancel_delegation"}}"#) == "cancel_delegation")
        #expect(live(title: "mcp__codeg-delegate__delegate_to_agent", kind: "other",
                     rawInput: #"{"agent_type":"codex","task":"do it"}"#,
                     meta: #"{"claudeCode":{"toolName":"mcp__codeg-delegate__delegate_to_agent"}}"#) == "delegate_to_agent")
    }

    @Test func namesALiveMonitorAMonitorNotTheShellCommandItsInputLooksLike() {
        let liveName = live(title: "Monitor", kind: "other",
                            rawInput: #"{"command":"for i in 1 2 3; do echo event-$i; sleep 2; done","description":"probe monitor"}"#,
                            meta: #"{"claudeCode":{"toolName":"Monitor"}}"#)
        #expect(liveName == "monitor")
        #expect(N.normalizeToolName("Monitor") == liveName)
        #expect(live(title: "Monitor", kind: "other",
                     rawInput: #"{"ws":{"url":"wss://ci.example.com/events"},"description":"CI events"}"#,
                     meta: #"{"claudeCode":{"toolName":"Monitor"}}"#) == "monitor")
        #expect(live(title: "Monitor", kind: "other", rawInput: #"{"command":"tail -f log"}"#, meta: nil) == "bash")
    }

    @Test func givesASandboxNetworkRequestOneNameInEitherSpelling() {
        let liveName = live(title: "SandboxNetworkAccess", kind: "other", rawInput: #"{"host":"example.com"}"#,
                            meta: #"{"claudeCode":{"toolName":"SandboxNetworkAccess"}}"#)
        #expect(liveName == "sandboxnetworkaccess")
        #expect(N.normalizeToolName("SandboxNetworkAccess") == liveName)
        #expect(N.normalizeToolName("sandboxnetworkaccess") == liveName)
    }

    @Test func keepsASandboxNetworkRequestByItsMetaNameWhateverItsInputCarries() {
        let rawInput = #"{"host":"example.com","url":"https://example.com/"}"#
        #expect(live(title: "example.com", kind: "other", rawInput: rawInput,
                     meta: #"{"claudeCode":{"toolName":"SandboxNetworkAccess"}}"#) == "sandboxnetworkaccess")
        #expect(live(title: "example.com", kind: "other", rawInput: rawInput, meta: nil) == "webfetch")
    }

    @Test func stillClassifiesATaskIdToolAsTaskWhenNoClaudeCodeMetaIsPresent() {
        #expect(live(title: "Some task", kind: "other", rawInput: #"{"task_id":"t1"}"#, meta: nil) == "task")
    }

    @Test func resolvesGrokCompanionToolsFromTheUnwrappedTitleOverTheInputShape() {
        let useTool = #"{"x.ai/tool":{"name":"use_tool"}}"#
        #expect(live(title: "codeg-mcp__cancel_delegation", kind: "other",
                     rawInput: #"{"task_id":"t1"}"#, meta: useTool) == "cancel_delegation")
        #expect(live(title: "codeg-mcp__get_delegation_status", kind: "other",
                     rawInput: #"{"task_ids":["t1"]}"#, meta: useTool) == "get_delegation_status")
        #expect(live(title: "codeg-mcp__delegate_to_agent", kind: "other",
                     rawInput: #"{"agent_type":"codex","task":"go"}"#, meta: useTool) == "delegate_to_agent")
    }

    @Test func ignoresMetaWhenClaudeCodeIsMissingOrMalformed() {
        #expect(live(title: "Recalled 3 memories", kind: "read", rawInput: nil, meta: nil) != "memory_recall")
        #expect(live(title: "Recalled 3 memories", kind: "read", rawInput: nil,
                     meta: #"{"somethingElse":{"toolName":"memory_recall"}}"#) != "memory_recall")
        #expect(live(title: "Recalled 3 memories", kind: "read", rawInput: nil,
                     meta: #"{"claudeCode":{"toolName":"   "}}"#) != "memory_recall")
    }
}

@Suite("inferLiveToolName query-bearing MCP calls")
struct QueryBearingMcpCallTests {
    @Test func keepsAnExplicitOpenCodeMcpToolTitle() {
        #expect(live(title: "codegraph_explore", kind: "other", rawInput: #"{"query":"find the auth flow"}"#) == "codegraph_explore")
    }

    @Test func stillClassifiesAQueryAsWebsearchWhenTheWireNamesWebsearch() {
        #expect(live(title: "web_search", kind: "other", rawInput: #"{"query":"Codeg"}"#) == "websearch")
        #expect(live(title: "Search", kind: "websearch", rawInput: #"{"query":"Codeg"}"#) == "websearch")
    }

    @Test func recognizesCodexWebSearchActionFrames() {
        #expect(live(title: "Open page: https://example.com", kind: "search",
                     rawInput: #"{"query":"Codeg","action":{"type":"openPage","url":"https://example.com"}}"#) == "websearch")
        #expect(live(title: "Find in page for 'ACP' in https://example.com", kind: "search",
                     rawInput: #"{"query":"Codeg","action":{"type":"findInPage","pattern":"ACP","url":"https://example.com"}}"#) == "websearch")
        #expect(live(title: "Search", kind: "other", rawInput: #"{"type":"webSearch","query":"Codeg"}"#) == "websearch")
    }

    @Test func recognizesGeminiWebSearchFramesByTheirTitle() {
        #expect(live(title: #"Searching the web for: "ACP protocol""#, kind: "search",
                     rawInput: #"{"query":"ACP protocol"}"#) == "websearch")
        #expect(live(title: #"Explain searching the web for: "x""#, kind: "search",
                     rawInput: #"{"query":"x"}"#) != "websearch")
    }

    @Test func doesNotInferWebsearchFromAQueryFieldAlone() {
        #expect(live(title: "MCP: tool", kind: "other", rawInput: #"{"query":"find usages"}"#) != "websearch")
        #expect(live(title: "Search for 'find usages'", kind: "search", rawInput: #"{"query":"find usages"}"#) == "grep")
    }
}

@Suite("normalizeToolName collapses delegate_to_agent across hosts")
struct DelegateToAgentAcrossHostsTests {
    @Test("%s -> delegate_to_agent", arguments: [
        "delegate_to_agent",
        "mcp__codeg-mcp__delegate_to_agent",
        "mcp__codeg-delegate__delegate_to_agent",
        "mcp__codeg__delegate_to_agent",
        "codeg-mcp/delegate_to_agent",
        "codeg-delegate/delegate_to_agent",
        "codeg-delegate.delegate_to_agent",
        "codeg-delegate:delegate_to_agent",
        "codeg_delegate__delegate_to_agent",
    ])
    func collapses(_ input: String) {
        #expect(N.normalizeToolName(input) == "delegate_to_agent")
    }

    @Test func doesNotMatchSuffixesWithoutASeparator() {
        #expect(N.normalizeToolName("xdelegate_to_agent") != "delegate_to_agent")
    }
}

@Suite("codex view_image")
struct CodexViewImageTests {
    @Test func isAReadLiveAndOnReload() {
        let path = "/tmp/nanguang-login/login-qr-new.png"
        #expect(live(title: "View Image \(path)", kind: "read", rawInput: #"{"path":"\#(path)"}"#) == "read")
        #expect(N.normalizeToolName("view_image") == "read")
    }
}

@Suite("normalizeToolName collapses delegation companion tools across hosts")
struct DelegationCompanionsAcrossHostsTests {
    @Test("%s -> get_delegation_status", arguments: [
        "get_delegation_status",
        "mcp__codeg-mcp__get_delegation_status",
        "mcp__codeg-delegate__get_delegation_status",
        "mcp__codeg__get_delegation_status",
        "codeg-mcp/get_delegation_status",
        "codeg-delegate/get_delegation_status",
        "codeg-delegate.get_delegation_status",
        "codeg-delegate:get_delegation_status",
    ])
    func getDelegationStatus(_ input: String) {
        #expect(N.normalizeToolName(input) == "get_delegation_status")
    }

    @Test("%s -> cancel_delegation", arguments: [
        "cancel_delegation",
        "mcp__codeg-mcp__cancel_delegation",
        "mcp__codeg-delegate__cancel_delegation",
        "mcp__codeg__cancel_delegation",
        "codeg-mcp/cancel_delegation",
        "codeg-delegate/cancel_delegation",
        "codeg-delegate.cancel_delegation",
        "codeg-delegate:cancel_delegation",
    ])
    func cancelDelegation(_ input: String) {
        #expect(N.normalizeToolName(input) == "cancel_delegation")
    }

    @Test func doesNotMatchSuffixesWithoutASeparator() {
        #expect(N.normalizeToolName("xget_delegation_status") != "get_delegation_status")
        #expect(N.normalizeToolName("xcancel_delegation") != "cancel_delegation")
    }
}

@Suite("normalizeToolName collapses ask_user_question across hosts")
struct AskUserQuestionAcrossHostsTests {
    @Test("%s -> question", arguments: [
        "question",
        "ask_user_question",
        "askuserquestion",
        "mcp__codeg-mcp__ask_user_question",
        "codeg-mcp/ask_user_question",
        "codeg-mcp.ask_user_question",
        "codeg-mcp:ask_user_question",
    ])
    func collapses(_ input: String) {
        #expect(N.normalizeToolName(input) == "question")
    }

    @Test func doesNotMatchASuffixWithoutASeparator() {
        #expect(N.normalizeToolName("xask_user_question") != "question")
    }
}

@Suite("normalizeToolName maps Antigravity's native ask_question")
struct AntigravityAskQuestionTests {
    @Test func collapsesTheBareNameItsHistoryParserKeeps() {
        #expect(N.normalizeToolName("ask_question") == "question")
    }

    @Test("leaves %s to its own card", arguments: [
        "mcp__deepwiki__ask_question",
        "deepwiki/ask_question",
        "deepwiki_ask_question",
        "deepwiki: ask_question",
    ])
    func leavesPrefixedToItsOwnCard(_ input: String) {
        #expect(N.normalizeToolName(input) != "question")
    }
}

@Suite("normalizeToolName collapses check_user_feedback across hosts")
struct CheckUserFeedbackAcrossHostsTests {
    @Test("%s -> check_user_feedback", arguments: [
        "check_user_feedback",
        "mcp__codeg-mcp__check_user_feedback",
        "mcp__codeg__check_user_feedback",
        "codeg-mcp/check_user_feedback",
        "codeg-mcp.check_user_feedback",
        "codeg-mcp:check_user_feedback",
    ])
    func collapses(_ input: String) {
        #expect(N.normalizeToolName(input) == "check_user_feedback")
    }

    @Test func doesNotMatchASuffixWithoutASeparator() {
        #expect(N.normalizeToolName("xcheck_user_feedback") != "check_user_feedback")
    }
}

@Suite("normalizeToolName collapses Codex goal tools across wrappers")
struct CodexGoalToolTests {
    @Test("%s -> %s", arguments: [
        ("create_goal", "create_goal"),
        ("functions.create_goal", "create_goal"),
        ("mcp__codeg__create_goal", "create_goal"),
        ("Goal updated (active): 分析 README 文件", "create_goal"),
        ("update_goal", "update_goal"),
        ("functions.update_goal", "update_goal"),
        ("mcp__codeg__update_goal", "update_goal"),
        ("Goal updated (complete): 分析 README 文件", "update_goal"),
    ])
    func collapses(_ input: String, _ expected: String) {
        #expect(N.normalizeToolName(input) == expected)
    }

    @Test func infersLiveCodexGoalUpdatesFromACPTitles() {
        #expect(live(title: "Goal updated (active): 分析 README 文件", kind: "other",
                     rawInput: #"{"objective":"分析 README 文件"}"#) == "create_goal")
        #expect(live(title: "Goal updated (complete): 分析 README 文件", kind: "other",
                     rawInput: #"{"status":"complete"}"#) == "update_goal")
    }
}

@Suite("inferLiveToolName codex collab detection")
struct CodexCollabDetectionTests {
    private let collabRaw = #"{"prompt":"run pnpm build","senderThreadId":"t1","receiverThreadIds":["t2"],"agentsStates":[],"status":"in_progress"}"#

    @Test func routesCollabToolCallsByRawInputShapeRegardlessOfTitle() {
        for title in ["spawn_agent", "wait_agent", "close_agent"] {
            #expect(live(title: title, kind: "other", rawInput: collabRaw) == "collab_agent")
        }
    }

    @Test func doesNotTreatTheSpawnAgentFunctionCallArgsAsCollab() {
        #expect(live(title: "spawn_agent", kind: "other", rawInput: #"{"agent_type":"worker","message":"go"}"#) == "agent")
    }
}

@Suite("normalizeToolName Grok terminal tool")
struct GrokTerminalToolTests {
    @Test func aliasesGroksRunTerminalCommandToBash() {
        #expect(N.normalizeToolName("run_terminal_command") == "bash")
    }
}

@Suite("normalizeToolName Windows shell tool")
struct WindowsShellToolTests {
    @Test func aliasesPowerShellToBashInEverySpellingTheParsersStore() {
        #expect(N.normalizeToolName("PowerShell") == "bash")
        #expect(N.normalizeToolName("powershell") == "bash")
    }

    @Test func doesNotSweepInUnrelatedNamesThatMerelyContainShell() {
        #expect(N.normalizeToolName("powershell_profile_lint") == "powershell_profile_lint")
    }

    @Test func agreesWithTheLivePathWhichClassifiesOnTheInputShape() {
        #expect(live(title: "Get-ChildItem -Recurse", kind: "execute",
                     rawInput: #"{"command":"Get-ChildItem -Recurse","description":"List files"}"#,
                     meta: #"{"claudeCode":{"toolName":"PowerShell","title":"List files"}}"#) == "bash")
        #expect(N.normalizeToolName(live(title: "PowerShell", kind: "execute", rawInput: nil,
                                         meta: #"{"claudeCode":{"toolName":"PowerShell"}}"#)) == "bash")
    }
}

@Suite("Antigravity terminal tool")
struct AntigravityTerminalToolTests {
    @Test func aliasesTheHistoryParsersRunCommandToBash() {
        #expect(N.normalizeToolName("run_command") == "bash")
    }

    @Test func classifiesTheLiveExecCallByItsInputShapeNotItsTitle() {
        #expect(live(title: "pnpm build", kind: "execute",
                     rawInput: #"{"command_line":"pnpm build","working_dir":"/Users/x/work/my-app"}"#) == "bash")
    }

    @Test func classifiesThePascalCaseEnvelopeAPermissionFrameCarries() {
        #expect(live(title: "pnpm build", kind: "execute",
                     rawInput: #"{"CommandLine":"pnpm build","Cwd":"/Users/x/work/my-app","WaitMsBeforeAsync":10000,"toolAction":"Running pnpm build"}"#) == "bash")
    }
}

@Suite("Antigravity MCP dispatch naming")
struct AntigravityMcpDispatchTests {
    @Test func collapsesTheServerToolNameBothPathsNowEmit() {
        #expect(N.normalizeToolName("codeg-mcp_delegate_to_agent") == "delegate_to_agent")
        #expect(N.normalizeToolName("codeg-mcp_get_delegation_status") == "get_delegation_status")
        #expect(N.normalizeToolName("codeg-mcp_ask_user_question") == "question")
        #expect(N.normalizeToolName("codeg-mcp_task_progress") == "task_progress")
    }
}

@Suite("Grok spawn_subagent routes to the Agent card")
struct GrokSpawnSubagentTests {
    @Test func aliasesTheRawSpawnSubagentNameToAgent() {
        #expect(N.normalizeToolName("spawn_subagent") == "agent")
    }

    @Test func classifiesTheLiveFrame1ToolCallByItsInputShape() {
        #expect(live(title: "spawn_subagent", kind: "other",
                     rawInput: #"{"description":"Explore test pages patterns","prompt":"Explore this Next.js app codebase…","subagent_type":"explore","capability_mode":"read-only"}"#,
                     meta: #"{"x.ai/tool":{"name":"spawn_subagent","kind":"task","label":"Subagent"}}"#) == "agent")
    }

    @Test func stillResolvesViaXaiToolNameWhenRawInputIsAbsent() {
        #expect(live(title: "Explore test pages patterns", kind: "other", rawInput: nil,
                     meta: #"{"x.ai/tool":{"name":"spawn_subagent","kind":"task"}}"#) == "agent")
    }
}

@Suite("inferLiveToolName cursor task and MCP shapes")
struct CursorTaskAndMcpShapeTests {
    @Test func routesCursorsTaskToolToTheAgentCardFromTheBareToolNameSnapshot() {
        #expect(live(title: "Task: Subagent task", kind: "other", rawInput: #"{"_toolName":"task"}"#) == "agent")
    }

    @Test func routesAFullyPopulatedCursorTaskPayloadToTheAgentCard() {
        #expect(live(title: "Task: run the build", kind: "other",
                     rawInput: #"{"_toolName":"task","prompt":"Run pnpm build and report back.","description":"run the build","subagentType":{"case":"generalPurpose","value":{}}}"#) == "agent")
    }

    @Test func resolvesCursorMcpCallsToProviderToolInsteadOfBash() {
        #expect(live(title: "codeg-mcp: delegate_to_agent", kind: "other",
                     rawInput: #"{"providerIdentifier":"codeg-mcp","toolName":"delegate_to_agent","args":{"agent_type":"codex","task":"run build"}}"#) == "delegate_to_agent")
        #expect(live(title: "srv: custom_tool", kind: "other",
                     rawInput: #"{"providerIdentifier":"srv","toolName":"custom_tool","args":{"command":"echo hi"}}"#) != "bash")
    }

    @Test func collapsesOtherCursorToolNameHintsToTheirCanonicalSnakeCaseNames() {
        #expect(live(title: "Create Plan: refactor", kind: "other",
                     rawInput: #"{"_toolName":"createPlan","name":"refactor"}"#) == "create_plan")
    }
}

@Suite("inferLiveToolName Grok plan-mode via x.ai/tool.kind")
struct GrokPlanModeTests {
    @Test func resolvesEnterPlanModeFromXaiToolKindDespiteTheMutatingTitle() {
        let name = live(title: "Plan mode entered", kind: "other", rawInput: #"{"variant":"EnterPlanMode"}"#,
                        meta: #"{"x.ai/tool":{"name":"enter_plan_mode","kind":"enter_plan","namespace":"grok_build","label":"Enter Plan Mode"}}"#)
        #expect(name == "enter_plan_mode")
        #expect(N.normalizeToolName(name) == "enterplanmode")
    }

    @Test func resolvesExitPlanModeFromXaiToolKind() {
        let name = live(title: "Plan: Exit", kind: "other", rawInput: #"{"variant":"ExitPlanMode"}"#,
                        meta: #"{"x.ai/tool":{"name":"exit_plan_mode","kind":"exit_plan"}}"#)
        #expect(name == "exit_plan_mode")
        #expect(N.normalizeToolName(name) == "exitplanmode")
    }

    @Test func doesNotHijackOtherGrokToolsCarryingXaiToolMeta() {
        #expect(live(title: "run_terminal_command", kind: "execute", rawInput: #"{"command":"pnpm build"}"#,
                     meta: #"{"x.ai/tool":{"name":"run_terminal_command","kind":"execute"}}"#) == "bash")
    }
}

@Suite("inferLiveToolName Grok identity via x.ai/tool.name")
struct GrokToolNameIdentityTests {
    private let meta = #"{"x.ai/tool":{"version":1,"name":"get_command_or_subagent_output","kind":"background_task_action","namespace":"grok_build","label":"Background Task","read_only":true}}"#

    @Test func keepsOneIdentityAcrossTheWholeMutatingLifecycle() {
        let announced = live(title: "get_command_or_subagent_output", kind: nil,
                             rawInput: #"{"task_ids":["term_b0d"],"timeout_ms":15000}"#, meta: meta)
        let inFlight = live(title: "Get task output: term_b0d9512484964551a5bac4f82a805ae2", kind: "other",
                            rawInput: #"{"variant":"TaskOutput","task_ids":["term_b0d"],"timeout_ms":15000}"#, meta: meta)
        let completed = live(title: "/bin/bash -lc 'pnpm dev -- --port 3001' (term_b0d)", kind: "other",
                             rawInput: #"{"variant":"TaskOutput","task_ids":["term_b0d"],"timeout_ms":15000}"#, meta: meta)
        #expect(announced == "get_command_or_subagent_output")
        #expect(inFlight == announced)
        #expect(completed == announced)
    }

    @Test func letsTheInputShapeKeepPriorityOverTheMetaName() {
        #expect(live(title: "Edit `/tmp/a.ts`", kind: "edit",
                     rawInput: #"{"file_path":"/tmp/a.ts","old_string":"a","new_string":"b"}"#,
                     meta: #"{"x.ai/tool":{"name":"search_replace","kind":"edit"}}"#) == "edit")
    }

    @Test func resolvesAnArgLessFrameFromTheMetaName() {
        #expect(live(title: "read_file", kind: nil, rawInput: nil,
                     meta: #"{"x.ai/tool":{"name":"read_file","kind":"read"}}"#) == "read")
    }

    @Test func ignoresTheGenericUseToolMcpEnvelope() {
        #expect(live(title: "codeg-mcp__delegate_to_agent", kind: "other",
                     rawInput: #"{"agent_type":"codex","task":"run build"}"#,
                     meta: #"{"x.ai/tool":{"name":"use_tool","kind":"use_tool"}}"#) == "delegate_to_agent")
    }
}

@Suite("normalizeToolName codex command-action titles")
struct CodexCommandActionTitleTests {
    @Test func resolvesSearchCommandActionsToGrep() {
        for title in [
            "Search for 'Tests run:' in com.forwayaudio.app",
            "Search for 'TODO'",
            "Search in 'src/lib'",
            "Search",
        ] {
            #expect(N.normalizeToolName(title) == "grep")
        }
    }

    @Test func resolvesListFilesCommandActionsToGlob() {
        #expect(N.normalizeToolName("List files in 'src/components'") == "glob")
        #expect(N.normalizeToolName("List files") == "glob")
    }

    @Test func keepsTheSiblingReadCommandActionOnRead() {
        #expect(N.normalizeToolName("Read file 'src/lib/a.ts'") == "read")
    }

    @Test func leavesUnrelatedTitlesAlone() {
        #expect(N.normalizeToolName("Research 'x' in y") == "Research 'x' in y")
        #expect(N.normalizeToolName("Searching for 'x'") == "Searching for 'x")
    }

    @Test func infersTheLiveNameFromTheTitleWhenThereIsNoRawInput() {
        #expect(live(title: "Search for 'Tests run:' in com.forwayaudio.app", kind: "search", rawInput: nil) == "grep")
        #expect(live(title: "List files in 'src'", kind: "read", rawInput: nil) == "glob")
    }
}

@Suite("inferLiveToolName codex plan_review marker")
struct CodexPlanReviewMarkerTests {
    @Test func classifiesTheSeededPlanReviewCallFromMetaCodexKind() {
        #expect(live(title: "Implement this plan?", kind: "switch_mode", rawInput: nil,
                     meta: #"{"codex":{"kind":"plan_review","planItemId":"item-7"}}"#) == "plan_review")
    }

    @Test func keepsTheMarkerAheadOfTheTitleHeuristic() {
        #expect(N.normalizeToolName("Implement this plan?") != "plan_review")
    }

    @Test func doesNotFireForOtherCodexMetaOrANonPlanReviewKind() {
        #expect(live(title: "Implement this plan?", kind: "switch_mode", rawInput: nil,
                     meta: #"{"codex":{"kind":"mcp_tool_call"}}"#) != "plan_review")
        #expect(N.codexMarksPlanReview(nil) == false)
        #expect(N.codexMarksPlanReview(m(#"{"codex":{"subagent":true}}"#)) == false)
        #expect(N.codexMarksPlanReview(m(#"{"codex":{"kind":"plan_review"}}"#)) == true)
    }

    @Test func stillLetsARealInputShapeWinOverTheMarker() {
        #expect(live(title: "Implement this plan?", kind: "execute", rawInput: #"{"command":"pnpm test"}"#,
                     meta: #"{"codex":{"kind":"plan_review"}}"#) == "bash")
    }
}

@Suite("inferLiveToolName resolves Qoder's authoritative _meta.qoder.toolName")
struct QoderToolNameTests {
    private func qoderMcpCall(_ tool: String, _ inputJSON: String, meta: Bool = true) -> String {
        live(title: "\(tool) (codeg-mcp MCP Server)", kind: "other", rawInput: inputJSON,
             meta: meta ? #"{"qoder":{"toolName":"mcp__codeg-mcp__\#(tool)"}}"# : nil)
    }

    @Test("resolves %s to its canonical card name", arguments: [
        ("delegate_to_agent", #"{"agent_type":"codex","task":"run pnpm build"}"#),
        ("get_delegation_status", #"{"task_ids":["081139e7"],"wait_ms":60000}"#),
        ("cancel_delegation", #"{"task_id":"081139e7"}"#),
        ("check_user_feedback", "{}"),
        ("ask_user_question", #"{"questions":[{"question":"which?"}]}"#),
        ("get_session_info", #"{"session_id":2122,"max_messages":20}"#),
        ("task_progress", #"{"message":"tests passing"}"#),
        ("task_complete", #"{"verdict":"success","summary":"done"}"#),
        ("create_automation", #"{"name":"nightly","prompt":"…","cron":"7 * * * *"}"#),
        ("create_work_task", #"{"title":"fix","prompt":"…"}"#),
    ])
    func resolvesToItsCanonicalCardName(_ tool: String, _ inputJSON: String) {
        let expected = tool == "ask_user_question" ? "question" : tool
        #expect(qoderMcpCall(tool, inputJSON) == expected)
    }

    @Test func resolvesTheFrameCapturedVerbatimFromQodercli1125() {
        #expect(live(title: "get_delegation_status (codeg-mcp MCP Server)", kind: "other",
                     rawInput: #"{"task_ids":["081139e7"]}"#,
                     meta: #"{"qoder":{"toolName":"mcp__codeg-mcp__get_delegation_status"}}"#) == "get_delegation_status")
    }

    @Test func provesTheTitleAloneCouldNeverHaveResolvedThese() {
        #expect(N.normalizeToolName("get_delegation_status (codeg-mcp MCP Server)") != "get_delegation_status")
        #expect(qoderMcpCall("task_progress", "{}", meta: false) != "task_progress")
    }

    @Test func rescuesCancelDelegationFromTheGenericTaskInputShape() {
        #expect(live(title: "cancel_delegation (codeg-mcp MCP Server)", kind: "other",
                     rawInput: #"{"task_id":"t1"}"#, meta: nil) == "task")
    }

    @Test func keepsInputShapeClassificationAheadOfTheMetaName() {
        #expect(live(title: "pnpm build", kind: "execute", rawInput: #"{"command":"pnpm build"}"#,
                     meta: #"{"qoder":{"toolName":"Bash"}}"#) == "bash")
        #expect(live(title: "Agent", kind: "think", rawInput: #"{"subagent_type":"explore","prompt":"…"}"#,
                     meta: #"{"qoder":{"toolName":"Agent"}}"#) == "agent")
    }

    @Test func resolvesQodersNativeToolsWhenTheInputShapeIsSilent() {
        #expect(live(title: "Exit plan mode", kind: "switch_mode", rawInput: #"{"plan":"do the thing"}"#,
                     meta: #"{"qoder":{"toolName":"ExitPlanMode"}}"#) == "exitplanmode")
        #expect(live(title: "Skill", kind: "other", rawInput: #"{"skill":"commit"}"#,
                     meta: #"{"qoder":{"toolName":"Skill"}}"#) == "skill")
    }

    @Test func ignoresAMalformedOrAbsentQoderMeta() {
        for meta in [nil, "{}", #"{"qoder":null}"#, #"{"qoder":{}}"#, #"{"qoder":{"toolName":""}}"#,
                     #"{"qoder":{"toolName":42}}"#] as [String?] {
            #expect(live(title: "whatever", kind: "other", rawInput: nil, meta: meta) == "whatever")
        }
    }
}

@Suite("toolCallMovedToBackground")
struct ToolCallMovedToBackgroundTests {
    @Test func readsTheCodexAcp110MarkerVerbatimOffTheWire() {
        #expect(N.toolCallMovedToBackground(m(#"{"jetbrains":{"air":{"asyncTasks":{"backgrounded":true}}}}"#)) == true)
        #expect(N.toolCallMovedToBackground(m(#"{"jetbrains":{"air":{"version":1,"asyncTasks":{"backgrounded":true}}}}"#)) == true)
    }

    @Test func staysFalseForEveryOtherMetaShape() {
        for meta in [
            nil,
            "{}",
            #"{"jetbrains":{"air":{"version":1,"sessionFailure":{"id":"x"}}}}"#,
            #"{"jetbrains":{"air":{"asyncTasks":{}}}}"#,
            #"{"jetbrains":{"air":{"asyncTasks":{"backgrounded":false}}}}"#,
            #"{"jetbrains":{"air":{"asyncTasks":{"backgrounded":"true"}}}}"#,
            #"{"jetbrains":{"air":{"asyncTasks":{"backgrounded":1}}}}"#,
            #"{"air":{"asyncTasks":{"backgrounded":true}}}"#,
            #"{"jetbrains":{"asyncTasks":{"backgrounded":true}}}"#,
            #"{"asyncTasks":{"backgrounded":true}}"#,
            #"{"jetbrains":{"air":"backgrounded"}}"#,
        ] as [String?] {
            #expect(N.toolCallMovedToBackground(m(meta)) == false, "\(String(describing: meta))")
        }
    }
}

@Suite("normalizeToolName collapses the codeg-mcp workbench companions")
struct WorkbenchCompanionTests {
    @Test("collapses every host spelling of %s", arguments: [
        "get_session_info",
        "task_progress",
        "task_complete",
        "create_automation",
        "create_work_task",
    ])
    func collapsesEveryHostSpelling(_ tool: String) {
        for spelling in [tool, "mcp__codeg-mcp__\(tool)", "mcp__codeg__\(tool)",
                         "codeg-mcp/\(tool)", "codeg-mcp.\(tool)", "codeg-mcp:\(tool)"] {
            #expect(N.normalizeToolName(spelling) == tool)
        }
    }

    @Test func keepsTaskProgressAndTaskCompleteOutOfTheGenericTaskTool() {
        #expect(N.normalizeToolName("task_progress") != "task")
        #expect(N.normalizeToolName("task_complete") != "task")
        #expect(N.normalizeToolName("task") == "task")
        #expect(N.normalizeToolName("task_update") == "taskupdate")
    }
}

@Suite("inferLiveToolName meta.opencode.toolName override")
struct OpenCodeToolNameOverrideTests {
    private func call(_ toolName: String, _ completedTitle: String?, _ kind: String?, _ rawInput: String) -> String {
        live(title: completedTitle, kind: kind, rawInput: rawInput, meta: #"{"opencode":{"toolName":"\#(toolName)"}}"#)
    }

    @Test func namesTheToolsWhoseInputShapeIsAmbiguous() {
        #expect(call("glob", nil, "search", #"{"pattern":"*.txt"}"#) == "glob")
        #expect(call("grep", "third", "search", #"{"pattern":"third","path":"/w"}"#) == "grep")
        #expect(call("lsp_diagnostics", "3 errors", "other", #"{"path":"/w/a.ts"}"#) == "lsp")
        #expect(call("context7_query-docs", "docs", "other", #"{"query":"effect"}"#) == "context7_query-docs")
    }

    @Test func keepsTheClassificationTheInputShapeAlreadyGotRight() {
        #expect(call("read", "notes.txt", "read", #"{"filePath":"/w/notes.txt"}"#) == "read")
        #expect(call("edit", "notes.txt", "edit", #"{"filePath":"/w/notes.txt","oldString":"a","newString":"b"}"#) == "edit")
        #expect(call("write", "a.ts", "edit", #"{"filePath":"/w/a.ts","content":"x"}"#) == "write")
        #expect(call("bash", "echo probe-ok", "execute", #"{"command":"echo probe-ok"}"#) == "bash")
        #expect(call("todowrite", "3 todos", "other", #"{"todos":[]}"#) == "todowrite")
        #expect(call("webfetch", "webfetch", "fetch", #"{"url":"https://x"}"#) == "webfetch")
        #expect(call("apply_patch", "apply_patch", "edit", #"{"patchText":"*** Begin Patch\n*** End Patch"}"#) == "apply_patch")
    }

    @Test func stillRoutesADelegationCompanionByItsOwnMarkers() {
        #expect(call("codeg-mcp_get_delegation_status", "status", "other", #"{"task_ids":["t1"]}"#) == "get_delegation_status")
        #expect(call("codeg-mcp_ask_user_question", "asked", "other", #"{"questions":[]}"#) == "question")
    }

    @Test func neverOverridesTheBackendsAuthoritativeSubAgentTitle() {
        #expect(live(title: "agent", kind: "think",
                     rawInput: #"{"description":"explore","prompt":"look around","subagent_type":"general"}"#,
                     meta: #"{"opencode":{"toolName":"task"}}"#) == "agent")
    }

    @Test func ignoresAMalformedOrAbsentMarker() {
        let rawInput = #"{"filePath":"/w/notes.txt"}"#
        #expect(live(title: "notes.txt", kind: nil, rawInput: rawInput, meta: nil) == "read")
        #expect(live(title: "notes.txt", kind: nil, rawInput: rawInput, meta: #"{"opencode":{}}"#) == "read")
        #expect(live(title: "notes.txt", kind: nil, rawInput: rawInput, meta: #"{"opencode":{"toolName":"  "}}"#) == "read")
        #expect(live(title: "notes.txt", kind: nil, rawInput: rawInput, meta: #"{"opencode":"glob"}"#) == "read")
    }
}

@Suite("inferLiveToolName meta.kiro.canonicalToolName override")
struct KiroCanonicalToolNameOverrideTests {
    private func call(_ kiroJSON: String, _ title: String, _ kind: String?, _ rawInput: String) -> String {
        live(title: title, kind: kind, rawInput: rawInput, meta: #"{"kiro":\#(kiroJSON)}"#)
    }

    @Test func namesTheCallsTheInputShapeGetsWrong() {
        #expect(call(#"{"toolName":"glob","canonicalToolName":"glob"}"#, "Finding *.txt in ws", "search",
                     #"{"pattern":"*.txt","path":"/w"}"#) == "glob")
        #expect(call(#"{"toolName":"read","canonicalToolName":"ls"}"#, "Reading listing ws", "read",
                     #"{"path":"/w"}"#) == "ls")
        #expect(call(#"{"toolName":"web_search","canonicalToolName":"websearch"}"#, "Searching the web", "search",
                     #"{"query":"agent client protocol"}"#) == "websearch")
    }

    @Test func keepsTheEditWriteSplitTheCanonicalInputEncodes() {
        #expect(call(#"{"toolName":"write","canonicalToolName":"edit"}"#, "Editing a.txt", "edit",
                     #"{"file_path":"/w/a.txt","old_string":"two","new_string":"2"}"#) == "edit")
        #expect(call(#"{"toolName":"write","canonicalToolName":"write"}"#, "Creating b.txt", "edit",
                     #"{"file_path":"/w/b.txt","content":"hello"}"#) == "write")
        #expect(call(#"{"toolName":"shell","canonicalToolName":"bash"}"#, "Running: ls /w", "execute",
                     #"{"command":"ls /w","description":"List it"}"#) == "bash")
    }

    @Test func resolvesAnMcpCallToItsCompanionTool() {
        #expect(call(#"{"toolName":"get_session_info","mcpServerName":"codeg-mcp","canonicalToolName":"mcp__codeg-mcp__get_session_info"}"#,
                     "Running: @codeg-mcp/get_session_info", nil,
                     #"{"__tool_use_purpose":"Look it up","session_id":7}"#) == "get_session_info")
    }

    @Test func ignoresKirosOwnToolNameWithoutTheBackendsStamp() {
        #expect(call(#"{"toolName":"write"}"#, "Editing a.txt", "edit",
                     #"{"file_path":"/w/a.txt","old_string":"a","new_string":"b"}"#) == "edit")
    }
}

/// `src/lib/adapters/qoder-codeg-mcp-pipeline.test.ts` — the identity-resolution
/// half only; the adapter passes it also exercises are not ported yet.
@Suite("Qoder live frames reach their card through every adapter pass")
struct QoderPipelineIdentityTests {
    private func qoderFrame(_ tool: String, _ inputJSON: String, meta: Bool = true) -> String {
        live(title: "\(tool) (codeg-mcp MCP Server)", kind: "other", rawInput: inputJSON,
             meta: meta ? #"{"qoder":{"toolName":"mcp__codeg-mcp__\#(tool)"}}"# : nil)
    }

    @Test("$tool survives identity resolution", arguments: [
        ("get_delegation_status", #"{"task_ids":["081139e7"],"wait_ms":60000}"#),
        ("cancel_delegation", #"{"task_id":"t1"}"#),
        ("check_user_feedback", "{}"),
        ("get_session_info", #"{"session_id":2122,"max_messages":20}"#),
        ("task_progress", #"{"message":"halfway"}"#),
        ("task_complete", #"{"verdict":"success","summary":"done"}"#),
    ])
    func survivesIdentityResolution(_ tool: String, _ inputJSON: String) {
        #expect(qoderFrame(tool, inputJSON) == tool)
    }

    @Test func holdsTheIdentityWhenTheFollowUpFrameCarriesNoMeta() {
        let opening = qoderFrame("task_progress", #"{"message":"halfway"}"#)
        #expect(opening == "task_progress")
        #expect(qoderFrame("task_progress", #"{"message":"halfway"}"#, meta: false) != "task_progress")
    }
}

/// JS string semantics the port relies on — not in the web suite, which gets
/// them for free. Expected values were taken from the web module under Node.
@Suite("JavaScript string semantics")
struct ToolNameNormalizerJSSemanticsTests {
    @Test func trimsJavaScriptsWhitespaceSetNotSwifts() {
        // U+FEFF is JS whitespace; U+0085 (NEL) is not.
        #expect(N.normalizeToolName("\u{FEFF}foo\u{FEFF}") == "foo")
        #expect(N.normalizeToolName("\u{0085}foo\u{0085}") == "\u{0085}foo\u{0085}")
    }

    @Test func wordBoundariesAreASCII() {
        // `\bagent\b`: a CJK letter is not a JS word character.
        #expect(N.normalizeToolName("子agent") == "agent")
        #expect(N.normalizeToolName("subagent") == "agent")
        #expect(N.normalizeToolName("myagent") == "myagent")
    }

    @Test func caseInsensitivityIsASCII() {
        // The Kelvin sign folds onto `k` in ICU but not in JS's /i.
        #expect(N.normalizeToolName("Goal updated (active): o") == "create_goal")
        #expect(N.normalizeToolName("\u{212A}all call") == "\u{212A}all call")
        #expect(N.normalizeToolName("x call") == "x")
    }

    @Test func lowerCasesWithTheFinalSigmaRule() {
        #expect(N.inferLiveToolName(title: "x", meta: m(#"{"claudeCode":{"toolName":"ΟΔΟΣ"}}"#)) == "οδος")
    }

    @Test func returnsAnUnmatchedNameWithItsOuterDecorationStripped() {
        #expect(N.normalizeToolName("  “Foo Bar”  ") == "Foo Bar")
        #expect(N.normalizeToolName("：foo") == "foo")
        #expect(N.normalizeToolName("   ") == "tool")
    }

    @Test func readsAToolNameOutOfALiveCallTitle() {
        #expect(N.normalizeToolName("`bash` call") == "bash")
        #expect(N.normalizeToolName("memory_recall") == "memory_re")
        #expect(N.normalizeToolName("foo: call") == "foo")
    }
}
