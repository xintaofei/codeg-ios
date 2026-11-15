import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/summarize.test.ts` (codeg 0.44).
@MainActor
struct ActivitySummarizeTests {
    private func part(_ toolName: String, _ input: String, failedWith errorText: String? = nil,
                      state: ToolCallState = .done, output: String? = "ok", id: String? = nil) -> ToolCallVM {
        let state: ToolCallState = errorText != nil ? .error : state
        return ToolCallVM(id: id ?? "s-\(UUID().uuidString)", rawName: toolName, kind: "", state: state,
                          input: input, output: errorText ?? output, content: nil, isError: state == .error)
    }

    private func step(_ vm: ToolCallVM, laterPolls: [ToolCallVM]? = nil) -> ActivityToolStep {
        ActivityToolStep(key: "tool:\(vm.id)", call: vm, tool: DescribeToolCall.describe(vm), laterPolls: laterPolls)
    }

    private func tool(_ toolName: String, _ input: String, failedWith errorText: String? = nil,
                      state: ToolCallState = .done, output: String? = "ok") -> ActivityStep {
        .tool(step(part(toolName, input, failedWith: errorText, state: state, output: output)))
    }

    /// The web's `failed` overrides: `{ state: "output-error", errorText: "Exit code 1" }`.
    private let failed = "Exit code 1"

    @Test("counts distinct files for reads and edits, calls for the rest")
    func countsDistinctFilesForReadsAndEditsCallsForTheRest() {
        let summary = ActivitySummarize.summarize([
            tool("Read", #"{"file_path":"/r/a.ts"}"#),
            tool("Read", #"{"file_path":"/r/a.ts"}"#),
            tool("Read", #"{"file_path":"/r/b.ts"}"#),
            tool("Edit", #"{"file_path":"/r/a.ts","old_string":"a","new_string":"b"}"#),
            tool("Edit", #"{"file_path":"/r/a.ts","old_string":"b","new_string":"c"}"#),
            tool("Grep", #"{"pattern":"x"}"#),
            tool("Grep", #"{"pattern":"y"}"#),
            tool("WebSearch", #"{"query":"q"}"#),
            tool("mcp__linear__get_issue", #"{"id":"1"}"#),
            tool("Bash", #"{"command":"ls"}"#),
        ])
        #expect(summary.steps == 10)
        #expect(summary.counts == ActivityCounts(commands: 1, editedFiles: 1, agents: 0, mcp: 1, web: 1,
                                                 readFiles: 2, searches: 2))
    }

    @Test("counts a monitor and a network request as steps, not commands")
    func countsAMonitorAndANetworkRequestAsStepsNotCommands() {
        let summary = ActivitySummarize.summarize([
            tool("Monitor", #"{"command":"tail -f log","description":"log errors"}"#),
            tool("SandboxNetworkAccess", #"{"host":"example.com"}"#),
            tool("Bash", #"{"command":"curl example.com"}"#),
        ])
        #expect(summary.steps == 3)
        #expect(summary.counts.commands == 1)
        #expect(summary.counts.web == 0)
    }

    @Test("calls a monitor or a network request recovered when the same one later succeeds")
    func callsAMonitorOrANetworkRequestRecoveredWhenTheSameOneLaterSucceeds() {
        let monitor = #"{"command":"tail -f log","description":"log errors"}"#
        let summary = ActivitySummarize.summarize([
            tool("Monitor", monitor, failedWith: failed),
            tool("SandboxNetworkAccess", #"{"host":"a.dev"}"#, failedWith: failed),
            tool("Monitor", monitor),
            tool("SandboxNetworkAccess", #"{"host":"a.dev"}"#),
        ])
        #expect(summary.failed == 2)
        #expect(summary.unrecovered == 0)
    }

    @Test("does not call a monitor or a network request recovered by another one")
    func doesNotCallAMonitorOrANetworkRequestRecoveredByAnotherOne() {
        let failedMonitor = tool("Monitor", #"{"command":"tail -f a.log","description":"a errors"}"#, failedWith: failed)
        let summary = ActivitySummarize.summarize([
            failedMonitor,
            tool("SandboxNetworkAccess", #"{"host":"a.dev"}"#, failedWith: failed),
            tool("Monitor", #"{"command":"tail -f b.log","description":"b errors"}"#),
            tool("SandboxNetworkAccess", #"{"host":"b.dev"}"#),
        ])
        #expect(summary.failed == 2)
        #expect(summary.unrecovered == 2)
        #expect(summary.firstUnrecoveredKey == failedMonitor.key)
    }

    @Test("does not take a command of the same text for a monitor started again")
    func doesNotTakeACommandOfTheSameTextForAMonitorStartedAgain() {
        let failedMonitor = tool("Monitor", #"{"command":"tail -f log","description":"log errors"}"#, failedWith: failed)
        let summary = ActivitySummarize.summarize([
            failedMonitor,
            tool("Bash", #"{"command":"tail -f log"}"#),
            tool("SandboxNetworkAccess", #"{"host":"b.dev"}"#),
        ])
        #expect(summary.unrecovered == 1)
        #expect(summary.firstUnrecoveredKey == failedMonitor.key)
    }

    @Test("calls a failure recovered when the same command later succeeds")
    func callsAFailureRecoveredWhenTheSameCommandLaterSucceeds() {
        let first = tool("Bash", #"{"command":"pnpm   test"}"#, failedWith: failed)
        let summary = ActivitySummarize.summarize([
            first,
            tool("Edit", #"{"file_path":"/r/a.ts","old_string":"a","new_string":"b"}"#),
            tool("Bash", #"{"command":"pnpm test"}"#),
        ])
        #expect(summary.failed == 1)
        #expect(summary.unrecovered == 0)
        #expect(summary.recoveredKeys.contains(first.key))
    }

    @Test("does not count a success before the failure, or a different command")
    func doesNotCountASuccessBeforeTheFailureOrADifferentCommand() {
        let failing = tool("Bash", #"{"command":"pnpm test"}"#, failedWith: failed)
        let summary = ActivitySummarize.summarize([
            tool("Bash", #"{"command":"pnpm test"}"#),
            failing,
            tool("Bash", #"{"command":"pnpm lint"}"#),
        ])
        #expect(summary.unrecovered == 1)
        #expect(summary.firstUnrecoveredKey == failing.key)
    }

    @Test("matches MCP retries on tool and arguments")
    func matchesMCPRetriesOnToolAndArguments() {
        let summary = ActivitySummarize.summarize([
            tool("mcp__gh__get", #"{"id":1}"#, failedWith: failed),
            tool("mcp__gh__get", #"{"id":2}"#),
        ])
        #expect(summary.unrecovered == 1)
    }

    @Test("counts interruptions apart from failures")
    func countsInterruptionsApartFromFailures() {
        let summary = ActivitySummarize.summarize([
            tool("Bash", #"{"command":"pnpm dev"}"#, failedWith: "[Request interrupted by user for tool use]"),
        ])
        #expect(summary.interrupted == 1)
        #expect(summary.failed == 0)
    }

    @Test("does not count bookkeeping calls as steps")
    func doesNotCountBookkeepingCallsAsSteps() {
        let summary = ActivitySummarize.summarize([
            tool("TodoWrite", #"{"todos":[]}"#),
            tool("wait", #"{"cell_id":"1"}"#),
            tool("mcp__codeg-mcp__get_delegation_status", #"{"task_ids":["t"]}"#),
        ])
        #expect(summary.steps == 0)
    }

    @Test("is running while any step is live")
    func isRunningWhileAnyStepIsLive() {
        #expect(ActivitySummarize.summarize([tool("Bash", #"{"command":"ls"}"#, state: .running)]).running)
    }

    @Test("counts a delegation whose task failed once, on the delegation")
    func countsADelegationWhoseTaskFailedOnceOnTheDelegation() {
        // Its checks are rows of their own and may all say so; the newest is
        // what the delegation reads, and the failure is the delegation's.
        let task = "a1b2c3d4"
        func check(_ id: String, _ status: String) -> ToolCallVM {
            part("mcp__codeg-mcp__get_delegation_status", #"{"task_ids":["\#(task)"]}"#,
                 output: #"{"task_id":"\#(task)","status":"\#(status)"}"#, id: id)
        }
        let polls = [check("c1", "running"), check("c2", "failed")]
        let delegation = step(part("mcp__codeg-mcp__delegate_to_agent", #"{"agent_type":"codex","task":"Run the checks."}"#,
                                   output: #"{"task_id":"\#(task)","status":"started"}"#),
                              laterPolls: polls)
        let summary = ActivitySummarize.summarize(
            [.tool(delegation)]
                + polls.map { .delegationPolls(key: "dpoll:\($0.id)", polls: [$0], status: .succeeded) }
                + [tool("mcp__codeg-mcp__get_delegation_status", #"{"task_ids":["\#(task)"]}"#)])
        #expect(summary.failed == 1)
        #expect(summary.firstUnrecoveredKey == delegation.key)
        #expect(summary.counts.agents == 1)
    }

    @Test("counts each background task once and its failure")
    func countsEachBackgroundTaskOnceAndItsFailure() {
        func poll(_ id: String, _ status: String, _ exit: Int) -> ToolCallVM {
            part("TaskOutput", #"{"task_id":"bg1","block":true}"#,
                 output: "<retrieval_status>success</retrieval_status>\n<task_id>bg1</task_id>\n<status>\(status)</status>\n<exit_code>\(exit)</exit_code>\n<output>x</output>",
                 id: id)
        }
        let summary = ActivitySummarize.summarize([
            .backgroundTasks(BackgroundTasksStep(key: "bg:p1", polls: [poll("p1", "running", 0), poll("p2", "completed", 2)],
                                                 status: .failed, launches: [:])),
        ])
        #expect(summary.steps == 1)
        #expect(summary.failed == 1)
    }

    @Test("a failed compaction is a failure, though not a step")
    func aFailedCompactionIsAFailureThoughNotAStep() {
        let summary = ActivitySummarize.summarize([
            .compaction(key: "compaction:1", CompactionInfo(before: nil, after: nil, running: false, failed: true)),
            .compaction(key: "compaction:2", CompactionInfo(before: 9, after: 3, running: false)),
        ])
        #expect(summary.steps == 0)
        #expect(summary.failed == 1)
        #expect(summary.firstUnrecoveredKey == "compaction:1")
    }
}
