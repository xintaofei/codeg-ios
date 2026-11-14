import Foundation
import Testing
@testable import Codeg

/// `src/lib/background-task.test.ts`, `src/lib/adapters/background-task-grouping.test.ts`
/// and the row logic of `rows/background-task-rows.test.tsx` (codeg 0.44).
///
/// Web parts map onto `ToolCallVM`: `output-available` → `.done`,
/// `input-available` → `.running`, `input-streaming` → `.inputStreaming`. The
/// web's forwarded `toolStatus` has no counterpart: iOS folds an unsettled
/// status into the call's state when it adapts it, so those cases are written
/// with the state they adapt to.
@MainActor
struct BackgroundTaskTests {
    // MARK: - Fixtures

    nonisolated static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static let completed = """
    <retrieval_status>success</retrieval_status>

    <task_id>bfb5xnq1t</task_id>

    <task_type>local_bash</task_type>

    <status>completed</status>

    <exit_code>0</exit_code>

    <output>
    running 0 tests
    test result: ok. 0 passed
    </output>
    """

    static let running = """
    <retrieval_status>timeout</retrieval_status>

    <task_id>bfb5xnq1t</task_id>

    <task_type>local_bash</task_type>

    <status>running</status>
    """

    static let failed = """
    <retrieval_status>success</retrieval_status>

    <task_id>bxx</task_id>

    <task_type>local_bash</task_type>

    <status>completed</status>

    <exit_code>1</exit_code>

    <output>error: build failed</output>
    """

    static let stopJSON = #"{"message":"Successfully stopped task: bebna5yf2 (cd /x; echo hi)","task_id":"bebna5yf2","task_type":"local_bash","command":"cd /x; echo hi"}"#

    static let launch = "Command running in background with ID: be7lh91re. Output is being written to: /private/tmp/x/tasks/be7lh91re.output. You will be notified when it completes."

    // Grok's shapes, from a real session: the launch acknowledgement, and the
    // poll's JSON `TaskOutput` envelope.
    static let grokLaunch = "Background task term_b0d9512484964551a5bac4f82a805ae2 started"

    nonisolated static let grokFailed = json([
        "type": "TaskOutput",
        "Result": [
            "task_id": "term_b0d",
            "command": "/bin/bash -lc 'pnpm dev -- --port 3001'",
            "status": "failed",
            "exit_code": 1,
            "started": "2026-07-30T12:52:48Z",
            "ended": "2026-07-30T12:52:49Z",
            "duration_secs": 0.787718,
            "output": "$ next dev --turbopack -- --port 3001\nInvalid project directory provided, no such directory: /Users/me/proj/--port\n",
            "truncated": false,
        ] as [String: Any],
    ])

    static let grokRunning = json([
        "type": "TaskOutput",
        "Result": [
            "task_id": "term_273",
            "command": "/bin/bash -lc 'pnpm exec next dev -p 3001'",
            "status": "running",
            "exit_code": NSNull(),
            "output": "▲ Next.js 16.0.0\n- Local: http://localhost:3001\n✓ Ready in 1.2s\n",
        ] as [String: Any],
    ])

    nonisolated static let pollInput = #"{"task_id":"bfb5xnq1t","block":true,"timeout":240000}"#

    /// The web's `poll(overrides)`.
    static func poll(id: String = "c1", toolName: String = "TaskOutput",
                     input: String? = BackgroundTaskTests.pollInput,
                     output: String? = BackgroundTaskTests.completed,
                     state: ToolCallState = .done) -> ToolCallVM {
        ToolCallVM(id: id, rawName: toolName, kind: "", state: state, input: input, output: output,
                   content: nil, isError: state == .error)
    }

    /// A Grok `get_command_or_subagent_output` poll of the failed dev-server task.
    static func grokPoll(id: String = "c1", output: String? = BackgroundTaskTests.grokFailed,
                         state: ToolCallState = .done,
                         input: String = #"{"task_ids":["term_b0d"],"timeout_ms":15000}"#) -> ToolCallVM {
        poll(id: id, toolName: "get_command_or_subagent_output", input: input, output: output, state: state)
    }

    private typealias B = BackgroundTask

    // MARK: - parseBackgroundTaskEnvelope

    @Test("parses a completed poll envelope")
    func parsesACompletedPollEnvelope() {
        let env = B.parseEnvelope(Self.completed)
        #expect(env?.kind == .poll)
        #expect(env?.taskId == "bfb5xnq1t")
        #expect(env?.taskType == "local_bash")
        #expect(env?.status == "completed")
        #expect(env?.exitCode == 0)
        #expect(env?.output?.contains("test result: ok") == true)
    }

    @Test("parses a still-running poll (no exit code / output)")
    func parsesAStillRunningPoll() {
        let env = B.parseEnvelope(Self.running)
        #expect(env?.kind == .poll)
        #expect(env?.status == "running")
        #expect(env?.retrievalStatus == "timeout")
        #expect(env != nil && env?.exitCode == nil)
        #expect(env != nil && env?.output == nil)
    }

    @Test("parses a non-zero exit code")
    func parsesANonZeroExitCode() {
        #expect(B.parseEnvelope(Self.failed)?.exitCode == 1)
    }

    @Test("parses a TaskStop ack JSON")
    func parsesATaskStopAckJSON() {
        let env = B.parseEnvelope(Self.stopJSON)
        #expect(env?.kind == .stop)
        #expect(env?.taskId == "bebna5yf2")
        #expect(env?.command == "cd /x; echo hi")
        #expect(env?.status == "stopped")
    }

    @Test("returns null for unrelated text and for the launch notice")
    func returnsNullForUnrelatedTextAndForTheLaunchNotice() {
        #expect(B.parseEnvelope("just some text") == nil)
        #expect(B.parseEnvelope(Self.launch) == nil)
        #expect(B.parseEnvelope(#"{"tasks":[]}"#) == nil)
        #expect(B.parseEnvelope(nil) == nil)
    }

    @Test("keeps output containing angle brackets intact (greedy close)")
    func keepsOutputContainingAngleBracketsIntact() {
        let env = B.parseEnvelope(
            "<retrieval_status>success</retrieval_status>\n<task_id>z</task_id>\n<status>completed</status>\n<exit_code>0</exit_code>\n<output>a <b> c </output>")
        #expect(env?.output == "a <b> c ")
    }

    // MARK: - parseBackgroundLaunch (`ActivityToolFacts.backgroundLaunchTaskId`)

    @Test("extracts the task id from a background launch result")
    func extractsTheTaskIdFromABackgroundLaunchResult() {
        #expect(ActivityToolFacts.backgroundLaunchTaskId(Self.launch) == "be7lh91re")
    }

    @Test("recognizes every wording Claude Code uses for a command moved to the background")
    func recognizesEveryWordingClaudeCodeUses() {
        // Claude Code 2.1.286's acknowledgements, verbatim. The steer one is
        // from a live run: the transcript stores it bare, claude-agent-acp
        // wraps it in a console fence on the wire.
        let steered = "Command was moved to the background (ID: bj0x9uqsf) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/x/tasks/bj0x9uqsf.output. You will be notified when it completes. If it is still running after 30m in the background, it will be stopped and you will be notified. To check interim output, use Read on that file path."
        #expect(ActivityToolFacts.backgroundLaunchTaskId(steered) == "bj0x9uqsf")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("```console\n" + steered + "\n```") == "bj0x9uqsf")
        #expect(ActivityToolFacts.backgroundLaunchTaskId(
            "Command did not complete within its 120s timeout and was moved to the background (ID: b3k9x2m1q). Output is being written to: /tmp/tasks/b3k9x2m1q.output. You will be notified when it completes.")
                == "b3k9x2m1q")
        #expect(ActivityToolFacts.backgroundLaunchTaskId(
            "Command was manually backgrounded by user with ID: bz81ab3cd. Output is being written to: /tmp/tasks/bz81ab3cd.output.")
                == "bz81ab3cd")
    }

    @Test("finds the timed-out acknowledgement after the output so far")
    func findsTheTimedOutAcknowledgementAfterTheOutputSoFar() {
        // Claude Code 2.1.312 puts what a command that outlived its timeout
        // printed before the sentence. Captured live.
        let timedOut = "tick-1\ntick-2\nCommand did not complete within its 2s timeout and was moved to the background (ID: bekp4cb00). Output is being written to: /private/tmp/claude-501/w/56c31d82/tasks/bekp4cb00.output. You will be notified when it completes. If it is still running after 30m in the background, it will be stopped and you will be notified. It is running now: do not start a second copy while it runs. If it is no longer needed, stop it with TaskStop. To check interim output, use Read on that file path."
        #expect(ActivityToolFacts.backgroundLaunchTaskId(timedOut) == "bekp4cb00")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("```console\n" + timedOut + "\n```") == "bekp4cb00")
    }

    @Test("recognizes OpenCode 2's background shell acknowledgement")
    func recognizesOpenCode2sBackgroundShellAcknowledgement() {
        #expect(ActivityToolFacts.backgroundLaunchTaskId(
            "Command moved to the background (shell ID: sh_17d9d0e2d001XnyG98WPjd9Z7G).\nOutput is streaming to: /w/xdg/data/opencode/shell/sh_17d9d0e2d001XnyG98WPjd9Z7G.log")
                == "sh_17d9d0e2d001XnyG98WPjd9Z7G")
    }

    @Test("leaves an MCP tool that was moved to the background alone")
    func leavesAnMCPToolThatWasMovedToTheBackgroundAlone() {
        #expect(ActivityToolFacts.backgroundLaunchTaskId(
            #"MCP tool "blocker/wait_for_answer" was moved to the background as task kjgwltsdi so that a message that arrived while it was running can reach you; it was not interrupted and keeps running"#)
                == nil)
    }

    @Test("extracts the task id from Grok's launch acknowledgement")
    func extractsTheTaskIdFromGroksLaunchAcknowledgement() {
        #expect(ActivityToolFacts.backgroundLaunchTaskId(Self.grokLaunch) == "term_b0d9512484964551a5bac4f82a805ae2")
    }

    @Test("returns null for non-launch text")
    func returnsNullForNonLaunchText() {
        #expect(ActivityToolFacts.backgroundLaunchTaskId(Self.completed) == nil)
        #expect(ActivityToolFacts.backgroundLaunchTaskId(nil) == nil)
    }

    // MARK: - Grok TaskOutput envelopes

    @Test("parses a failed Grok poll (command, exit code, output)")
    func parsesAFailedGrokPoll() {
        let env = B.parseEnvelope(Self.grokFailed)
        #expect(env?.kind == .poll)
        #expect(env?.taskId == "term_b0d")
        #expect(env?.command == "/bin/bash -lc 'pnpm dev -- --port 3001'")
        #expect(env?.status == "failed")
        #expect(env?.exitCode == 1)
        #expect(env?.output?.contains("Invalid project directory") == true)
    }

    @Test("parses a still-running Grok poll")
    func parsesAStillRunningGrokPoll() {
        let env = B.parseEnvelope(Self.grokRunning)
        #expect(env?.status == "running")
        #expect(env != nil && env?.exitCode == nil)
        #expect(env?.output?.contains("Ready in") == true)
    }

    @Test("expands a MultiResult into one envelope per task")
    func expandsAMultiResultIntoOneEnvelopePerTask() {
        let envs = B.parseEnvelopes(Self.json([
            "type": "TaskOutput",
            "MultiResult": [
                "result_count": 2,
                "results": [
                    ["task_id": "term_a", "status": "completed", "exit_code": 0] as [String: Any],
                    ["task_id": "term_b", "status": "running"],
                ],
            ] as [String: Any],
        ]))
        #expect(envs.map(\.taskId) == ["term_a", "term_b"])
    }

    @Test("maps a killed task to the stopped kind")
    func mapsAKilledTaskToTheStoppedKind() {
        let env = B.parseEnvelope(#"{"type":"TaskOutput","Result":{"task_id":"term_a","status":"killed","command":"sleep 900"}}"#)
        #expect(env?.kind == .stop)
    }

    @Test("ignores non-TaskOutput JSON, TaskNotFound, and truncated envelopes")
    func ignoresNonTaskOutputJSONTaskNotFoundAndTruncatedEnvelopes() {
        // A sub-agent poll of the SAME tool: a different payload → a plain row.
        #expect(B.parseEnvelope(#"{"type":"SubagentCompleted","Result":{"subagent_id":"s1","turns":3}}"#) == nil)
        #expect(B.parseEnvelope(#"{"type":"TaskOutput","TaskNotFound":{"task_id":"x"}}"#) == nil)
        #expect(B.parseEnvelope(String(Self.grokFailed.dropLast(20))) == nil)
    }

    @Test("routes Grok polls into the background lane, sub-agent polls out of it")
    func routesGrokPollsIntoTheBackgroundLaneSubAgentPollsOutOfIt() {
        // Settled poll → by its envelope.
        #expect(B.isToolCall(Self.grokPoll()))
        // In-flight poll → by `{task_ids, timeout_ms}`, before any output.
        #expect(B.isToolCall(Self.grokPoll(output: nil, state: .running)))
        // The same tool polling a sub-agent whose payload is an UNKNOWN shape:
        // out of the lane.
        #expect(!B.isToolCall(Self.grokPoll(output: #"{"type":"SubagentCompleted","Result":{"subagent_id":"s1","turns":3}}"#)))
        // …and out of it when a settled poll carries no output at all (an
        // older backend that dropped the envelope), rather than a lane row
        // stuck on "running". (The web's `errorText: ""` twin is the same
        // call here.)
        #expect(!B.isToolCall(Self.grokPoll(output: nil, state: .done)))
    }

    // Adapted: the web's promoted orphan (`output-available` with a forwarded
    // `in_progress` status) adapts to a running call on iOS.
    @Test("keeps a live poll whose status has not settled yet")
    func keepsALivePollWhoseStatusHasNotSettledYet() {
        #expect(B.isToolCall(Self.grokPoll(output: nil, state: .running)))
    }

    @Test("builds a failed row carrying the command and exit code")
    func buildsAFailedRowCarryingTheCommandAndExitCode() {
        let rows = B.buildRows([
            Self.grokPoll(id: "c1", output: nil, state: .running),
            Self.grokPoll(id: "c2"),
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.taskId == "term_b0d")
        #expect(rows.first?.badge == .failed)
        #expect(rows.first?.exitCode == 1)
        #expect(rows.first?.command == "/bin/bash -lc 'pnpm dev -- --port 3001'")
        #expect(rows.first?.output?.contains("Invalid project directory") == true)
        #expect(rows.first?.pollCount == 2)
    }

    @Test("marks a failure with no exit code as failed, not completed")
    func marksAFailureWithNoExitCodeAsFailedNotCompleted() {
        let rows = B.buildRows([
            Self.grokPoll(output: #"{"type":"TaskOutput","Result":{"task_id":"term_z","status":"failed","command":"x"}}"#),
        ])
        #expect(rows.first?.badge == .failed)
    }

    // MARK: - Grok SubagentCompleted envelopes (0.2.11x sub-agent polls)

    static let subagentDone = json([
        "type": "SubagentCompleted",
        "subagent_id": "019f9432-e0d8-74c3-bd02-0772c4e04a65",
        "subagent_type": "explore",
        "description": "Explore test pages",
        "status": "completed",
        "tool_calls": 35,
        "turns": 1,
        "duration_ms": 63775,
        "output": "## Codebase exploration summary",
    ])

    @Test("parses the flat envelope into a sub-agent poll row")
    func parsesTheFlatEnvelopeIntoASubAgentPollRow() {
        let env = B.parseEnvelope(Self.subagentDone)
        #expect(env?.kind == .poll)
        #expect(env?.taskId == "019f9432-e0d8-74c3-bd02-0772c4e04a65")
        #expect(env?.taskType == "subagent")
        #expect(env?.status == "completed")
        #expect(env?.command == "[subagent:explore] Explore test pages")
        #expect(env?.output == "## Codebase exploration summary")
    }

    @Test("maps a cancelled sub-agent to the stopped kind")
    func mapsACancelledSubAgentToTheStoppedKind() {
        #expect(B.parseEnvelope(#"{"type":"SubagentCompleted","subagent_id":"s1","status":"cancelled"}"#)?.kind == .stop)
    }

    @Test("rejects an empty envelope (nothing identifying)")
    func rejectsAnEmptyEnvelope() {
        #expect(B.parseEnvelope(#"{"type":"SubagentCompleted"}"#) == nil)
    }

    @Test("routes a settled flat sub-agent poll into the background lane")
    func routesASettledFlatSubAgentPollIntoTheBackgroundLane() {
        #expect(B.isToolCall(Self.grokPoll(output: Self.subagentDone)))
        let rows = B.buildRows([Self.grokPoll(output: Self.subagentDone)])
        #expect(rows.count == 1)
        #expect(rows.first?.badge == .completed)
        #expect(rows.first?.command == "[subagent:explore] Explore test pages")
        #expect(rows.first?.isSubagent == true)
    }

    // MARK: - CodeBuddy TaskOutput snapshots

    // Verbatim shapes from a real session: a plain-text report. The
    // `Response:` section repeats the `--- RESULT ---` body — only the tail is
    // shown.
    static let codeBuddyAgentDone = """
    Task ID: agent-5af21a8e9ff04b19
    Status: completed
    Duration: 19s
    Started: 2026-09-15T05:42:08.169Z
    Ended: 2026-09-15T05:42:27.996Z
    Agent Type: general-purpose
    Task ID (for resume): agent-5af21a8e9ff04b19

    Prompt:
    Run the command `pnpm build` in /Users/xggz/my/my-app.

    Response:
    Build succeeded (exit code 0).

    --- RESULT ---
    Build succeeded (exit code 0).

    **Summary:** Next.js 16.1.7 production build completed with no errors.
    """

    static let codeBuddyAgentRunning = """
    Task ID: agent-77
    Status: running
    Duration: 3s
    Task ID (for resume): agent-77

    --- RESULT ---
    (no new progress since last check)

    (Task still running. You will be notified automatically when it completes.)

    <system-reminder data-role="tool-hint">
    Agent agent-77 is still running. You will be automatically notified via a <task-notification> message when it finishes — do NOT poll TaskOutput in a loop.
    </system-reminder>
    """

    static let codeBuddyShell = """
    Shell ID: bash-9
    Command: pnpm dev
    Status: completed
    Duration: 2m 4s
    Timestamp: 2026-09-15T05:42:27.996Z

    Stdout (full):
    ready on :3000

    Stderr: (no output)
    """

    @Test("parses a completed agent snapshot into a sub-agent row")
    func parsesACompletedAgentSnapshotIntoASubAgentRow() {
        let env = B.parseEnvelope(Self.codeBuddyAgentDone)
        #expect(env?.kind == .poll)
        #expect(env?.taskId == "agent-5af21a8e9ff04b19")
        #expect(env?.taskType == "subagent")
        #expect(env?.status == "completed")
        #expect(env != nil && env?.exitCode == nil)
        let output = env?.output ?? ""
        #expect(output.contains("Next.js 16.1.7 production build"))
        // Only the RESULT tail.
        #expect(!output.contains("Task ID (for resume)"))
        #expect(!output.contains("Response:"))
        #expect(!output.contains("Prompt:"))
    }

    @Test("strips the model-facing tool hint from a running snapshot")
    func stripsTheModelFacingToolHintFromARunningSnapshot() {
        let env = B.parseEnvelope(Self.codeBuddyAgentRunning)
        #expect(env?.status == "running")
        let output = env?.output ?? ""
        #expect(output.contains("no new progress"))
        #expect(!output.contains("system-reminder"))
        #expect(!output.contains("do NOT poll TaskOutput"))
    }

    @Test("maps a cancelled worker to the stopped kind")
    func mapsACancelledWorkerToTheStoppedKind() {
        #expect(B.parseEnvelope("Task ID: agent-9\nStatus: cancelled\n\n--- RESULT ---\n(Task was cancelled)")?.kind == .stop)
    }

    @Test("keeps a team-member snapshot's note (no RESULT separator)")
    func keepsATeamMemberSnapshotsNote() {
        let env = B.parseEnvelope(
            "Task ID: agent-t\nStatus: running\n\nThis is a team member task (status: running). TaskOutput does not wait for teammates.")
        #expect(env?.taskId == "agent-t")
        #expect(env?.output == "This is a team member task (status: running). TaskOutput does not wait for teammates.")
    }

    @Test("parses a background shell snapshot (command + stdout/stderr)")
    func parsesABackgroundShellSnapshot() {
        let env = B.parseEnvelope(Self.codeBuddyShell)
        #expect(env?.taskId == "bash-9")
        #expect(env?.taskType == "local_bash")
        #expect(env?.command == "pnpm dev")
        #expect(env?.status == "completed")
        #expect(env != nil && env?.exitCode == nil)
        #expect(env?.output?.contains("ready on :3000") == true)
        #expect(env?.output?.contains("Duration:") == false)
    }

    @Test("is not fooled by header labels echoed in the captured output")
    func isNotFooledByHeaderLabelsEchoedInTheCapturedOutput() {
        let snapshot = """
        Shell ID: bash-7
        Command: ./emit-header.sh
        Status: completed
        Duration: 3s
        Timestamp: 2026-09-15T05:42:27.996Z

        Stdout (full):
        Status: running
        Duration: 99s
        Timestamp: 2026-01-01T00:00:00.000Z
        decoy

        Stderr: (no output)
        """
        let env = B.parseEnvelope(snapshot)
        #expect(env?.command == "./emit-header.sh")
        #expect(env?.status == "completed")
        let output = env?.output ?? ""
        #expect(output.contains("Status: running"))
        #expect(output.contains("decoy"))
        #expect(!output.contains("./emit-header.sh"))

        let row = B.buildRows([Self.poll(input: nil, output: snapshot)]).first
        #expect(row?.badge == .completed)
        #expect(row?.command == "./emit-header.sh")
        #expect(row?.output?.contains("decoy") == true)
    }

    @Test("abstains whenever the header cannot be located with certainty")
    func abstainsWheneverTheHeaderCannotBeLocatedWithCertainty() {
        let multiline = """
        Shell ID: bash-9
        Command: pnpm install &&
        pnpm build
        Status: completed
        Duration: 12s
        Timestamp: 2026-09-15T05:42:27.996Z

        Stdout (full):
        done

        Stderr: (no output)
        """
        // (1) An ordinary multiline command: the run is not at its offset.
        #expect(B.parseEnvelope(multiline) == nil)

        // (2) A heredoc forging the run EXACTLY right after `Command:` — two
        // candidate runs, so nothing is claimed.
        #expect(B.parseEnvelope("""
        Shell ID: bash-3
        Command: cat <<'EOF'
        Status: completed
        Duration: fake
        Timestamp: fake

        Stdout (full):
        EOF
        Status: running
        Duration: 1s
        Timestamp: 2026-09-15T05:42:27.996Z

        Stdout (full):
        hi
        """) == nil)

        // (3) A single-line command whose OUTPUT reproduces the whole run.
        #expect(B.parseEnvelope("""
        Shell ID: bash-4
        Command: ./emit-header.sh
        Status: completed
        Duration: 3s
        Timestamp: 2026-09-15T05:42:27.996Z

        Stdout (full):
        Status: running
        Duration: 99s
        Timestamp: 2026-01-01T00:00:00.000Z

        Stdout (full):
        decoy
        """) == nil)

        // Abstaining means a plain row — never a truncated command or a status
        // lifted out of unrelated text.
        let row = B.buildRows([Self.poll(input: nil, output: multiline)]).first
        #expect(row != nil)
        #expect(row?.command == nil)
        #expect(row?.output == nil)
    }

    @Test("does not hijack ordinary tool output that merely mentions a task id")
    func doesNotHijackOrdinaryToolOutputThatMerelyMentionsATaskId() {
        #expect(B.parseEnvelope("Task ID: agent-1 was dispatched earlier.") == nil)
        #expect(B.parseEnvelope("Task ID: agent-1\nsomething else entirely") == nil)
        #expect(B.parseEnvelope("Shell ID: s1\nStatus: done") == nil)
        // A shell-shaped prefix whose header never closes.
        #expect(B.parseEnvelope("Shell ID: s1\nCommand: ls\nStatus: running") == nil)
        #expect(B.parseEnvelope("Shell ID: s1\nCommand: ls\nStatus: running\nDuration: 1s") == nil)
        #expect(!B.isToolCall(Self.poll(toolName: "Bash", input: nil, output: "Shell ID: s1\nCommand: ls\nStatus: running")))
    }

    @Test("renders a settled snapshot as a completed row carrying its report")
    func rendersASettledSnapshotAsACompletedRowCarryingItsReport() {
        let row = B.buildRows([Self.poll(input: nil, output: Self.codeBuddyAgentDone)]).first
        // Regression: the report used to be dropped and the row stuck on "running".
        #expect(row?.badge == .completed)
        #expect(row?.isSubagent == true)
        #expect(row?.output?.contains("Next.js 16.1.7 production build") == true)
    }

    // MARK: - Grok sub-agent rows

    // The tail of a real 0.2.9x `TaskOutput.Result.output` for a polled
    // sub-agent: two machine-facing blocks addressed to the parent model.
    static let report = [
        "## Build Result: **Succeeded**",
        "",
        "Optimized production build completed successfully.",
        "",
        "<subagent_meta>id=019fe6bf-0bcb-70c2-a02d-e5c006dfc32a, type=general-purpose, tool_calls=1, turns=1, duration_ms=18651</subagent_meta>",
        "",
        "<subagent_result>",
        "subagent_id: 019fe6bf-0bcb-70c2-a02d-e5c006dfc32a",
        "subagent_type: general-purpose",
        #"To continue this subagent's conversation, use resume_from="019fe6bf-0bcb-70c2-a02d-e5c006dfc32a"."#,
        "</subagent_result>",
    ].joined(separator: "\n")

    static let subagentTaskOutput = json([
        "type": "TaskOutput",
        "Result": [
            "task_id": "019fe6bf-0bcb-70c2-a02d-e5c006dfc32a",
            "command": "[subagent:general-purpose] Run pnpm build",
            "status": "completed",
            "exit_code": 0,
            "output": report,
        ] as [String: Any],
    ])

    @Test("strips the meta / result scaffolding from the displayed output")
    func stripsTheMetaResultScaffoldingFromTheDisplayedOutput() {
        #expect(B.stripGrokSubagentScaffolding(Self.report)
                == "## Build Result: **Succeeded**\n\nOptimized production build completed successfully.")
    }

    @Test("returns non-Grok output untouched")
    func returnsNonGrokOutputUntouched() {
        let plain = "$ next build\n✓ Compiled successfully\n"
        #expect(B.stripGrokSubagentScaffolding(plain) == plain)
        #expect(B.stripGrokSubagentScaffolding(nil) == nil)
    }

    @Test("flags a 0.2.9x `[subagent:…]` TaskOutput row and cleans its output")
    func flagsASubagentTaskOutputRowAndCleansItsOutput() {
        let rows = B.buildRows([Self.grokPoll(output: Self.subagentTaskOutput)])
        #expect(rows.count == 1)
        #expect(rows.first?.isSubagent == true)
        let output = rows.first?.output ?? ""
        #expect(!output.contains("<subagent_meta>"))
        #expect(!output.contains("resume_from"))
        #expect(output.contains("## Build Result"))
    }

    @Test("leaves an ordinary background shell row alone")
    func leavesAnOrdinaryBackgroundShellRowAlone() {
        #expect(B.buildRows([Self.poll(output: Self.completed)]).first?.isSubagent == false)
    }

    // MARK: - isBackgroundTaskToolCall

    @Test("matches by raw tool name (historical path)")
    func matchesByRawToolName() {
        #expect(B.isToolCall(Self.poll(toolName: "TaskOutput", output: nil)))
        #expect(B.isToolCall(Self.poll(toolName: "TaskStop", input: #"{"task_id":"x"}"#, output: nil)))
    }

    @Test("matches by output envelope (live `task` alias)")
    func matchesByOutputEnvelope() {
        #expect(B.isToolCall(Self.poll(toolName: "task", input: nil)))
    }

    @Test("matches an in-flight poll by input shape (no output yet)")
    func matchesAnInFlightPollByInputShape() {
        #expect(B.isToolCall(Self.poll(toolName: "task", output: nil, state: .running)))
    }

    @Test("does NOT match a real sub-agent Agent call")
    func doesNotMatchARealSubAgentAgentCall() {
        #expect(!B.isToolCall(Self.poll(toolName: "Agent", input: #"{"subagent_type":"Explore","task_id":"x","block":true}"#,
                                        output: "the agent's final answer")))
    }

    @Test("does NOT match get_delegation_status or cancel_delegation")
    func doesNotMatchDelegationStatusOrCancel() {
        #expect(!B.isToolCall(Self.poll(toolName: "mcp__codeg-mcp__get_delegation_status", input: #"{"task_ids":["a"]}"#,
                                        output: #"{"tasks":[{"task_id":"a","status":"running"}]}"#)))
        #expect(!B.isToolCall(Self.poll(toolName: "mcp__codeg-mcp__cancel_delegation", input: #"{"task_id":"a"}"#,
                                        output: "Canceled task a")))
    }

    @Test("does NOT match TaskUpdate")
    func doesNotMatchTaskUpdate() {
        #expect(!B.isToolCall(Self.poll(toolName: "TaskUpdate", input: #"{"taskId":"1","status":"completed"}"#, output: "ok")))
    }

    // MARK: - buildBackgroundTaskRows

    @Test("collapses repeated polls of one task into a single completed row")
    func collapsesRepeatedPollsOfOneTaskIntoASingleCompletedRow() {
        let rows = B.buildRows([
            Self.poll(id: "p1", output: Self.running),
            Self.poll(id: "p2", output: Self.completed),
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.badge == .completed)
        #expect(rows.first?.exitCode == 0)
        #expect(rows.first?.pollCount == 2)
        #expect(rows.first?.output?.contains("test result: ok") == true)
        #expect(rows.first?.taskId == "bfb5xnq1t")
    }

    @Test("keeps parallel tasks as separate rows")
    func keepsParallelTasksAsSeparateRows() {
        let rows = B.buildRows([
            Self.poll(id: "a", output: Self.completed),
            Self.poll(id: "b", input: #"{"task_id":"bxx","block":true}"#, output: Self.failed),
        ])
        #expect(rows.map(\.taskId) == ["bfb5xnq1t", "bxx"])
        #expect(rows.last?.badge == .failed)
        #expect(rows.last?.exitCode == 1)
    }

    @Test("marks an in-flight poll as running")
    func marksAnInFlightPollAsRunning() {
        let rows = B.buildRows([Self.poll(output: nil, state: .running)])
        #expect(rows.first?.badge == .running)
        #expect(rows.first?.isInFlight == true)
    }

    @Test("drops an in-flight poll whose task_id has not streamed in yet")
    func dropsAnInFlightPollWhoseTaskIdHasNotStreamedInYet() {
        // claude-agent-acp emits an arg-less initial tool_call (rawInput `{}`)
        // and fills the real args only on a later update.
        #expect(B.buildRows([Self.poll(input: "{}", output: nil, state: .running)]).isEmpty)
    }

    @Test("does not stack repeated id-less in-flight re-polls into duplicate rows")
    func doesNotStackRepeatedIdLessInFlightRePolls() {
        let rows = B.buildRows([
            Self.poll(id: "done", output: Self.completed),
            Self.poll(id: "x1", input: "{}", output: nil, state: .running),
            Self.poll(id: "x2", input: nil, output: nil, state: .running),
            Self.poll(id: "x3", input: "{}", output: nil, state: .inputStreaming),
        ])
        #expect(rows.map(\.taskId) == ["bfb5xnq1t"])
    }

    // Adapted: the web's promoted orphan (`output-available`, forwarded
    // status `pending`) is a running call once iOS adapts it.
    @Test("drops a promoted orphan (output-available but status still unsettled)")
    func dropsAPromotedOrphan() {
        let rows = B.buildRows([
            Self.poll(id: "done", output: Self.completed),
            Self.poll(id: "orphan", input: "{}", output: nil, state: .running),
        ])
        #expect(rows.map(\.taskId) == ["bfb5xnq1t"])
    }

    @Test("still shows an id-less poll once it carries an envelope")
    func stillShowsAnIdLessPollOnceItCarriesAnEnvelope() {
        let noIdEnvelope = "<retrieval_status>success</retrieval_status>\n<status>completed</status>\n<exit_code>0</exit_code>\n<output>ok</output>"
        let rows = B.buildRows([Self.poll(input: nil, output: noIdEnvelope)])
        #expect(rows.count == 1)
        #expect(rows.first?.badge == .completed)
    }

    @Test("derives a stopped badge + command from a TaskStop ack")
    func derivesAStoppedBadgeAndCommandFromATaskStopAck() {
        let rows = B.buildRows([Self.poll(toolName: "TaskStop", input: #"{"task_id":"bebna5yf2"}"#, output: Self.stopJSON)])
        #expect(rows.first?.badge == .stopped)
        #expect(rows.first?.command == "cd /x; echo hi")
    }

    // MARK: - groupConsecutiveBackgroundTasks (adapter)

    private static let groupPollOutput = "<retrieval_status>success</retrieval_status>\n<task_id>bfb5xnq1t</task_id>\n<task_type>local_bash</task_type>\n<status>completed</status>\n<exit_code>0</exit_code>\n<output>done</output>"

    private func taskPoll(_ id: String) -> RenderPart {
        .tool(Self.poll(id: id, input: #"{"task_id":"bfb5xnq1t","block":true,"timeout":1000}"#, output: Self.groupPollOutput))
    }

    private func kinds(_ parts: [RenderPart]) -> [String] {
        parts.map { part in
            switch part {
            case .text: return "text"
            case .tool: return "tool-call"
            case .backgroundTaskGroup: return "background-task-group"
            case .delegationStatusGroup: return "delegation-status-group"
            default: return "other"
            }
        }
    }

    private func polls(_ part: RenderPart?) -> [String]? {
        if case .backgroundTaskGroup(let polls)? = part { return polls.map(\.id) }
        return nil
    }

    @Test("collapses a consecutive run of polls into one group")
    func collapsesAConsecutiveRunOfPollsIntoOneGroup() {
        let parts = MessageRender.groupConsecutiveBackgroundTasks([.text("before"), taskPoll("p1"), taskPoll("p2"), .text("after")])
        #expect(kinds(parts) == ["text", "background-task-group", "text"])
        #expect(polls(parts.dropFirst().first) == ["p1", "p2"])
    }

    @Test("does NOT merge polls separated by other content")
    func doesNotMergePollsSeparatedByOtherContent() {
        let parts = MessageRender.groupConsecutiveBackgroundTasks([taskPoll("p1"), .text("interruption"), taskPoll("p2")])
        #expect(kinds(parts) == ["background-task-group", "text", "background-task-group"])
    }

    @Test("leaves a command next to the polls as its own call")
    func leavesACommandNextToThePollsAsItsOwnCall() {
        let bash = ToolCallVM(id: "b1", rawName: "bash", kind: "", state: .done, input: #"{"command":"ls"}"#,
                              output: "file.txt", content: nil, isError: false)
        let parts = MessageRender.groupConsecutiveBackgroundTasks([.tool(bash), taskPoll("p1")])
        #expect(kinds(parts) == ["tool-call", "background-task-group"])
        if case .tool(let vm)? = parts.first { #expect(vm.toolName == "bash") }
    }

    // Adapted: `mergeAdjacentBackgroundTaskGroups` ("merges adjacent groups
    // (cross-turn poll rounds)" / "does not merge groups separated by other
    // parts") has no iOS counterpart — consecutive assistant turns are merged
    // BEFORE they are adapted, so each poll round lands in one run.
    @Test("draws a poll a turn as one lane across the turns of a reply")
    func drawsAPollATurnAsOneLaneAcrossTheTurnsOfAReply() {
        func turn(_ id: String, _ blocks: [ContentBlock]) -> MessageTurn {
            MessageTurn(id: id, role: .assistant, blocks: blocks, timestamp: Date(timeIntervalSince1970: 1_792_000_000))
        }
        func pollBlocks(_ id: String) -> [ContentBlock] {
            [.toolUse(id: id, name: "TaskOutput", inputPreview: #"{"task_id":"bfb5xnq1t","block":true}"#,
                      status: .unknown, meta: nil),
             .toolResult(id: id, outputPreview: Self.groupPollOutput, isError: false, agentStats: nil)]
        }
        let merged = TranscriptTimeline.merge([turn("a1", pollBlocks("p1")), turn("a2", pollBlocks("p2"))])
        let together = MessageRender.adaptTurn(merged)
        #expect(kinds(together) == ["background-task-group"])
        #expect(polls(together.first) == ["p1", "p2"])

        let apart = MessageRender.adaptTurn(turn("a3", pollBlocks("p3") + [.text("x")] + pollBlocks("p4")))
        #expect(kinds(apart) == ["background-task-group", "text", "background-task-group"])
    }

    // iOS regression: `CompanionDetect` reads Grok's `{task_ids, timeout_ms}`
    // poll as a `get_delegation_status` check by its shape; the delegation
    // lane must leave it to the background lane, as the web does.
    @Test("keeps a Grok poll out of the delegation-poll lane")
    func keepsAGrokPollOutOfTheDelegationPollLane() {
        let grok = Self.grokPoll()
        #expect(grok.companion == .delegationStatus)
        let parts = MessageRender.groupLanes([.tool(grok)])
        #expect(kinds(parts) == ["background-task-group"])
    }

    // The other way round: a genuine `get_delegation_status` poll stays a
    // delegation poll even when the child's report quotes a background
    // envelope's tags — the name decides first, as on the web.
    @Test("keeps a named delegation check in its lane whatever its report quotes")
    func keepsANamedDelegationCheckInItsLane() {
        let check = ToolCallVM(
            id: "s1", rawName: "mcp__codeg-mcp__get_delegation_status", kind: "", state: .done,
            input: #"{"task_ids":["a"],"wait_ms":0}"#,
            output: #"{"tasks":[{"task_id":"a","status":"failed","text":"Bad <task_type>local_bash</task_type> handling"}]}"#,
            content: nil, isError: false)
        #expect(check.companion == .delegationStatus)
        let parts = MessageRender.groupLanes([.tool(check)])
        #expect(kinds(parts) == ["delegation-status-group"])
    }

    // MARK: - The row (`rows/background-task-rows.test.tsx`)

    private static func pollCompleted(_ output: String = "BUILD OK MARKER") -> String {
        "<retrieval_status>success</retrieval_status>\n<task_id>bfb5xnq1t</task_id>\n<task_type>local_bash</task_type>\n<status>completed</status>\n<exit_code>0</exit_code>\n<output>\(output)</output>"
    }

    @Test("folds repeated polls into one row with the final status")
    func foldsRepeatedPollsIntoOneRowWithTheFinalStatus() {
        let rows = B.buildRows([
            Self.poll(id: "p1", output: "<retrieval_status>timeout</retrieval_status>\n<task_id>bfb5xnq1t</task_id>\n<task_type>local_bash</task_type>\n<status>running</status>"),
            Self.poll(id: "p2", output: Self.pollCompleted()),
        ])
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        #expect(row.badge == .completed)
        #expect(B.rowStatus(row) == .succeeded)
        #expect(B.shortId(row) == "bfb5xnq1t")
        #expect(row.pollCount == 2)
    }

    @Test("shows the output's first line")
    func showsTheOutputsFirstLine() {
        guard let row = B.buildRows([Self.poll(output: Self.pollCompleted("BUILD OK MARKER\nsecond line"))]).first else {
            Issue.record("expected a row"); return
        }
        #expect(B.rowDetail(row, launch: nil) == "BUILD OK MARKER")
    }

    @Test("names a non-zero exit as the failure it is")
    func namesANonZeroExitAsTheFailureItIs() {
        let failed = "<retrieval_status>success</retrieval_status>\n<task_id>bfb5xnq1t</task_id>\n<task_type>local_bash</task_type>\n<status>completed</status>\n<exit_code>1</exit_code>\n<output>first\nboom</output>"
        guard let row = B.buildRows([Self.poll(output: failed)]).first else {
            Issue.record("expected a row"); return
        }
        #expect(B.rowStatus(row) == .failed)
        #expect(row.exitCode == 1)
        // A failure's last line is usually the error itself.
        #expect(B.rowDetail(row, launch: nil) == "boom")
    }

    @Test("says it is running while a poll is in flight")
    func saysItIsRunningWhileAPollIsInFlight() {
        guard let row = B.buildRows([Self.poll(output: nil, state: .running)]).first else {
            Issue.record("expected a row"); return
        }
        #expect(row.badge == .running)
        #expect(B.rowStatus(row) == .running)
        #expect(B.staysInView(row))
    }

    // iOS addition: the web's `rowStatus` — a settled "still running" poll is a
    // snapshot, which neither spins nor stays in view of a folded reply.
    @Test("reads a settled still-running poll as a snapshot")
    func readsASettledStillRunningPollAsASnapshot() {
        guard let row = B.buildRows([Self.poll(output: Self.running)]).first else {
            Issue.record("expected a row"); return
        }
        #expect(row.badge == .running)
        #expect(B.rowStatus(row) == .succeeded)
        #expect(!B.staysInView(row))
    }

    @Test("names a Grok poll after the command it polled")
    func namesAGrokPollAfterTheCommandItPolled() {
        let output = Self.json([
            "type": "TaskOutput",
            "Result": [
                "task_id": "term_b0d",
                "command": "/bin/bash -lc 'pnpm dev -- --port 3001'",
                "status": "failed",
                "exit_code": 1,
                "output": "INVALID DIRECTORY MARKER",
            ] as [String: Any],
        ])
        guard let row = B.buildRows([Self.grokPoll(output: output)]).first else {
            Issue.record("expected a row"); return
        }
        #expect(B.rowStatus(row) == .failed)
        #expect(row.exitCode == 1)
        #expect(B.rowDetail(row, launch: nil) == "/bin/bash -lc 'pnpm dev -- --port 3001' · INVALID DIRECTORY MARKER")
    }

    @Test("draws a Grok sub-agent's report as prose, without the wire scaffolding")
    func drawsAGrokSubAgentsReportAsProseWithoutTheWireScaffolding() {
        let output = Self.json([
            "type": "TaskOutput",
            "Result": [
                "task_id": "019fe6bf",
                "command": "[subagent:general-purpose] Run pnpm build",
                "status": "completed",
                "exit_code": 0,
                "output": "## Build Result\n\nBUILD REPORT MARKER\n\n<subagent_meta>id=019fe6bf, tool_calls=1</subagent_meta>\n\n<subagent_result>\nresume_from=\"019fe6bf\"\n</subagent_result>",
            ] as [String: Any],
        ])
        guard let row = B.buildRows([Self.grokPoll(output: output,
                                                   input: #"{"task_ids":["019fe6bf"],"timeout_ms":300000}"#)]).first else {
            Issue.record("expected a row"); return
        }
        #expect(row.isSubagent)
        let shown = B.displayOutput(row) ?? ""
        #expect(shown.contains("BUILD REPORT MARKER"))
        #expect(!shown.contains("subagent_meta"))
        #expect(!shown.contains("resume_from"))
        // A sub-agent is not named by its pseudo-command.
        #expect(B.rowDetail(row, launch: nil) == "## Build Result")
    }

    // iOS addition: iOS draws no ANSI colours, so the escapes leave a shell's
    // output before it is shown.
    @Test("takes the ANSI escapes out of a shell's output")
    func takesTheANSIEscapesOutOfAShellsOutput() {
        guard let row = B.buildRows([Self.poll(output: Self.pollCompleted("\u{1B}[32m✓\u{1B}[0m built"))]).first else {
            Issue.record("expected a row"); return
        }
        #expect(B.displayOutput(row) == "✓ built")
        #expect(B.rowDetail(row, launch: nil) == "✓ built")
    }
}
