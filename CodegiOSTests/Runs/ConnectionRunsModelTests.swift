import Foundation
import Testing
@testable import Codeg

/// The connection's running list and predicted prompt as both streams feed
/// them (web `HYDRATE_FROM_SNAPSHOT` / `ASYNC_TASK` / `SESSION_STARTED` /
/// `PROMPT_SUGGESTION` / `DELEGATION_RUNNING` reducers, plus the
/// `DelegationProvider` bindings).
private func snapshot(seq: UInt64?, externalId: String? = "s1", _ extra: [String: Any] = [:]) throws -> LiveSessionSnapshot {
    var json: [String: Any] = ["connection_id": "c1", "status": "connected"]
    if let externalId { json["external_id"] = externalId }
    if let seq { json["event_seq"] = seq }
    json.merge(extra) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: json)
    return try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: data)
}

private func row(_ id: String, state: String = "running", type: String = "shell") -> [String: Any] {
    ["task_id": id, "name": "job \(id)", "task_type": type, "description": "", "show_in_transcript": true,
     "can_stop": true, "state": state]
}

private func spawn(_ id: String, type: String = "shell") -> AcpEvent {
    .asyncTask(AsyncTaskDelta(taskId: id, spawned: true, name: "job \(id)", taskType: type, canStop: true))
}

private func settle(_ id: String, _ state: String = "completed") -> AcpEvent {
    .asyncTask(AsyncTaskDelta(taskId: id, spawned: false, state: state))
}

/// Counts callbacks without a captured `var` (main-actor closures may be
/// inferred `@Sendable`).
@MainActor
private final class Counter {
    var value = 0
}

@MainActor
@Suite struct ConnectionRunsHydrateTests {
    @Test func aFreshSnapshotReplacesRowsByIdAndTakesTheCurrentState() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, ["async_tasks": [row("t1")]]), connection: "c1")
        #expect(model.asyncTasks.map(\.state) == ["running"])
        try model.hydrate(snapshot(seq: 9, [
            "async_tasks": [row("t1", state: "completed"), row("t2")],
            "background_outstanding_tasks": [["task_id": "a1", "kind": "agent", "started_at_ms": 1] as [String: Any]],
            "delegated_children": ["child-a"],
            "prompt_suggestion": "  Run the tests  ",
        ]), connection: "c1")
        #expect(model.asyncTasks.map(\.taskId) == ["t1", "t2"])
        #expect(model.asyncTasks.map(\.state) == ["completed", "running"])
        #expect(model.backgroundTasks.map(\.taskId) == ["a1"])
        #expect(model.delegatedChildren == ["child-a"])
        #expect(model.promptSuggestion == "Run the tests")
        #expect(model.lastSeq == 9)
    }

    @Test func aStaleSnapshotOnlyAddsWhatWasNeverSeen() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 10, ["async_tasks": [row("t1")], "prompt_suggestion": "old guess"]),
                          connection: "c1")
        model.apply(settle("t1"), seq: 11)
        model.apply(.promptSuggestion(text: nil), seq: 12)
        // Taken at seq 10 again: it still says running, and still has the guess.
        try model.hydrate(snapshot(seq: 10, [
            "async_tasks": [row("t1"), row("t2")],
            "delegated_children": ["child-a"],
            "prompt_suggestion": "old guess",
        ]), connection: "c1")
        #expect(model.asyncTasks.map(\.state) == ["completed", "running"])
        #expect(model.promptSuggestion == nil)
        #expect(model.delegatedChildren.isEmpty, "current state is only taken from a fresh snapshot")
        #expect(model.lastSeq == 12)
    }

    @Test func ignoresTheTaskRowsOfAnotherSessionInAStaleSnapshot() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 5, externalId: "s1"), connection: "c1")
        try model.hydrate(snapshot(seq: 2, externalId: "s-old", ["async_tasks": [row("t1")]]), connection: "c1")
        #expect(model.asyncTasks.isEmpty)
    }

    // The watcher was away when the connection forked: its `session_started`
    // never arrived. The next fresh snapshot names the new session — the old
    // session's rows go (nothing would settle them), the new one's are taken,
    // and a later stale read of the old session changes nothing.
    @Test func aFreshSnapshotOfAnotherSessionReplacesTheRowsOfTheOldOne() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 10, externalId: "s1", ["async_tasks": [row("old")]]), connection: "c1")
        try model.hydrate(snapshot(seq: 20, externalId: "s2", ["async_tasks": [row("new")]]), connection: "c1")
        #expect(model.asyncTasks.map(\.taskId) == ["new"])
        #expect(model.sessionID == "s2")
        try model.hydrate(snapshot(seq: 15, externalId: "s1", ["async_tasks": [row("old")]]), connection: "c1")
        #expect(model.asyncTasks.map(\.taskId) == ["new"])
    }

    @Test func aDifferentConnectionStartsOver() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 50, ["async_tasks": [row("t1")], "prompt_suggestion": "x"]), connection: "c1")
        try model.hydrate(snapshot(seq: 3), connection: "c2")
        #expect(model.connectionID == "c2")
        #expect(model.asyncTasks.isEmpty)
        #expect(model.promptSuggestion == nil)
        #expect(model.lastSeq == 3, "a new connection's low seq is not stale")
    }

    @Test func eventsBeforeAnySnapshotAreNotApplied() {
        let model = ConnectionRunsModel()
        model.apply(spawn("t1"), seq: 1)
        #expect(model.asyncTasks.isEmpty)
    }
}

@MainActor
@Suite struct ConnectionRunsEventTests {
    @Test func appliesEachEventOnceByItsSeq() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        model.apply(spawn("t1"), seq: 2)
        model.apply(settle("t1"), seq: 3)
        // The other stream's copy of an event already applied.
        model.apply(.asyncTask(AsyncTaskDelta(taskId: "t1", spawned: false, state: "running")), seq: 3)
        #expect(model.asyncTasks.first?.state == "completed")
        #expect(model.liveRuns.count == 0)
    }

    @Test func aForkClearsTheTaskTableAndTheSuggestion() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1, externalId: "s1", ["async_tasks": [row("t1")], "prompt_suggestion": "x"]),
                          connection: "c1")
        model.apply(.sessionStarted(sessionId: "s1"), seq: 2)
        #expect(model.asyncTasks.count == 1, "a replayed announcement changes nothing")
        #expect(model.promptSuggestion == "x")
        model.apply(.sessionStarted(sessionId: "s2"), seq: 3)
        #expect(model.asyncTasks.isEmpty)
        #expect(model.promptSuggestion == nil)
        #expect(model.sessionID == "s2")
    }

    @Test func theOutstandingSetIsReplacedWhole() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        model.apply(.backgroundActivity(outstandingTasks: [
            BackgroundOutstandingTask(taskId: "a1", kind: "agent", toolUseId: nil, description: "dig", startedAtMs: 5),
        ]), seq: 2)
        #expect(model.liveRuns.subagents.count == 1)
        // Absent on the wire = none.
        model.apply(.backgroundActivity(outstandingTasks: []), seq: 3)
        #expect(model.liveRuns.subagents.isEmpty)
    }

    @Test func delegationsRunUntilTheParentStopsListingTheChild() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        let info = DelegationInfo(parentToolUseId: "call-1", childConnectionId: "child-a",
                                  childConversationId: 9, agentType: .codex, taskPreview: "fix the build")
        model.apply(.delegationStarted(info), seq: 2)
        model.apply(.delegationChildRunning(childConnectionId: "child-a", running: true), seq: 3)
        model.apply(.delegationChildRunning(childConnectionId: "child-a", running: true), seq: 4)
        #expect(model.liveRuns.delegations.map(\.binding?.info.taskPreview) == ["fix the build"])

        var completed = info
        completed.taskPreview = nil
        model.apply(.delegationCompleted(completed, succeeded: true, errorCode: nil), seq: 5)
        #expect(model.liveRuns.delegations.isEmpty, "a finished binding leaves with its completion")
        #expect(model.delegationBindings.first?.info.taskPreview == "fix the build", "the binding keeps who it was")
        model.apply(.delegationChildRunning(childConnectionId: "child-a", running: false), seq: 6)
        #expect(model.delegatedChildren.isEmpty)
    }

    @Test func aSnapshotReseedsTheBindingsOfDelegationsAlreadyRunning() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 4, [
            "delegated_children": ["child-a"],
            "active_delegations": [[
                "parent_tool_use_id": "call-1", "child_connection_id": "child-a", "child_conversation_id": 9,
                "agent_type": "codex", "task_preview": "fix the build", "task_id": "",
            ] as [String: Any]],
        ]), connection: "c1")
        let run = try #require(model.liveRuns.delegations.first)
        #expect(run.binding?.info.agentType == .codex)
        #expect(run.binding?.info.taskPreview == "fix the build")
        #expect(run.binding?.info.taskId == nil, "an empty task id is none")
    }

    @Test func aDelegationThatEndedUnheardLosesItsRunningBinding() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        let running = DelegationInfo(parentToolUseId: "call-1", childConnectionId: "child-a",
                                     childConversationId: 9, agentType: .codex, taskPreview: "fix the build")
        let done = DelegationInfo(parentToolUseId: "call-2", childConnectionId: "child-b",
                                  childConversationId: 10, agentType: .gemini, taskPreview: "lint")
        model.apply(.delegationStarted(running), seq: 2)
        model.apply(.delegationStarted(done), seq: 3)
        model.apply(.delegationCompleted(done, succeeded: false, errorCode: "timeout"), seq: 4)
        // A stale snapshot (from before what was applied) proves nothing.
        try model.hydrate(snapshot(seq: 3), connection: "c1")
        #expect(model.delegationBindings.contains { $0.parentToolUseId == "call-1" })
        // A fresh one that no longer lists call-1: it ended while nobody listened.
        try model.hydrate(snapshot(seq: 9), connection: "c1")
        #expect(!model.delegationBindings.contains { $0.parentToolUseId == "call-1" })
        // What this model saw end stays: it says how it ended.
        #expect(model.delegationBindings.first { $0.parentToolUseId == "call-2" }?.status == .err)
        // One the fresh snapshot restates keeps running.
        model.apply(.delegationStarted(running), seq: 10)
        try model.hydrate(snapshot(seq: 12, ["active_delegations": [[
            "parent_tool_use_id": "call-1", "child_connection_id": "child-a", "child_conversation_id": 9,
            "agent_type": "codex",
        ] as [String: Any]]]), connection: "c1")
        #expect(model.delegationBindings.first { $0.parentToolUseId == "call-1" }?.status == .running)
    }

    @Test func aGoneConnectionTakesEverythingWithIt() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1, ["async_tasks": [row("t1")], "delegated_children": ["x"],
                                            "prompt_suggestion": "go"]), connection: "c1")
        model.connectionGone("other")
        #expect(model.liveRuns.count == 2, "a report about another connection changes nothing")
        model.connectionGone("c1")
        #expect(model.liveRuns == .empty)
        #expect(model.promptSuggestion == nil)
        #expect(model.connectionID == nil)
    }

    @Test func aTurnTheAgentStartedOnItsOwnSettlingAsksForTheTranscript() throws {
        let model = ConnectionRunsModel()
        let refreshes = Counter()
        model.onAutonomousTurnSettled = { refreshes.value += 1 }
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        model.apply(spawn("autonomous-turn-1", type: "turn"), seq: 2)
        model.apply(spawn("t1"), seq: 3)
        model.apply(settle("t1"), seq: 4)
        #expect(refreshes.value == 0, "only a turn's end brings content")
        model.apply(settle("autonomous-turn-1"), seq: 5)
        #expect(refreshes.value == 1)
        // A later correction of an already-settled turn is not a second end.
        model.apply(settle("autonomous-turn-1", "failed"), seq: 6)
        #expect(refreshes.value == 1)
    }

    @Test func aFreshSnapshotThatSettlesATurnAlsoAsks() throws {
        let model = ConnectionRunsModel()
        let refreshes = Counter()
        model.onAutonomousTurnSettled = { refreshes.value += 1 }
        try model.hydrate(snapshot(seq: 1, ["async_tasks": [row("turn-1", type: "turn")]]), connection: "c1")
        try model.hydrate(snapshot(seq: 9, ["async_tasks": [row("turn-1", state: "completed", type: "turn")]]),
                          connection: "c1")
        #expect(refreshes.value == 1)
    }
}

@MainActor
@Suite struct PromptSuggestionTests {
    @Test func isSetByItsEventAndWithdrawnByNull() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        model.apply(.promptSuggestion(text: " Run the tests "), seq: 2)
        #expect(model.promptSuggestion == "Run the tests")
        model.apply(.promptSuggestion(text: nil), seq: 3)
        #expect(model.promptSuggestion == nil)
        model.apply(.promptSuggestion(text: "   "), seq: 4)
        #expect(model.promptSuggestion == nil, "blank is none")
    }

    @Test func survivesTheTurnsEndButNotTheNextPrompt() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1), connection: "c1")
        model.apply(.promptSuggestion(text: "commit this"), seq: 2)
        model.apply(.turnComplete(stopReason: "end_turn"), seq: 3)
        #expect(model.promptSuggestion == "commit this")
        // Any client's prompt spends it.
        model.apply(.statusChanged(status: .prompting), seq: 4)
        #expect(model.promptSuggestion == nil)
    }

    @Test func aLocalSendSpendsIt() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1, ["prompt_suggestion": "commit this"]), connection: "c1")
        model.clearPromptSuggestion()
        #expect(model.promptSuggestion == nil)
    }

    @Test func aFreshSnapshotSaysWhatItIs() throws {
        let model = ConnectionRunsModel()
        try model.hydrate(snapshot(seq: 1, ["prompt_suggestion": "first"]), connection: "c1")
        try model.hydrate(snapshot(seq: 2), connection: "c1")
        #expect(model.promptSuggestion == nil, "omitted = none")
    }

    @Test func isOfferedOnlyWhereSendingItCouldFollow() {
        func offer(draft: String = "", attachments: Bool = false, inFlight: Bool = false,
                   steering: Bool = false, queueEmpty: Bool = true) -> String? {
            PromptSuggestionGate.offered("Run the tests", draft: draft, hasAttachments: attachments,
                                         inFlight: inFlight, steering: steering, queueEmpty: queueEmpty)
        }
        #expect(offer() == "Run the tests")
        #expect(offer(draft: "my own words") == nil)
        #expect(offer(draft: " ") == nil, "anything typed hides the placeholder")
        #expect(offer(attachments: true) == nil)
        #expect(offer(inFlight: true) == nil)
        #expect(offer(steering: true) == nil)
        #expect(offer(queueEmpty: false) == nil)
        #expect(PromptSuggestionGate.offered(nil, draft: "", hasAttachments: false, inFlight: false,
                                             steering: false, queueEmpty: true) == nil)
        #expect(PromptSuggestionGate.offered("  ", draft: "", hasAttachments: false, inFlight: false,
                                             steering: false, queueEmpty: true) == nil)
    }
}
