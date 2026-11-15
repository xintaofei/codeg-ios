import Foundation
import Testing
@testable import Codeg

/// The wire shapes behind the running list and the predicted prompt (Rust
/// `AcpEvent::{AsyncTask, BackgroundActivity, DelegationStarted,
/// DelegationCompleted, DelegationChildRunning, PromptSuggestion}` and the
/// `LiveSessionSnapshot` fields that restate them), decoded through the
/// shared snake_case decoder like every frame.
private func event(_ json: String) throws -> AcpEvent {
    try CodegJSON.decoder.decode(AcpEvent.self, from: Data(json.utf8))
}

@Suite struct RunsEventDecodingTests {
    @Test func anAsyncTaskDeltaKeepsAbsentFieldsAbsent() throws {
        let decoded = try event(#"""
        {"type":"async_task","delta":{"task_id":"t1","spawned":false,"state":"running",
         "usage":{"total_tokens":1200,"tool_uses":3,"duration_ms":4500},"current_agent":""}}
        """#)
        guard case .asyncTask(let delta) = decoded else { Issue.record("decoded \(decoded)"); return }
        #expect(delta.taskId == "t1")
        #expect(!delta.spawned)
        #expect(delta.state == "running")
        #expect(delta.name == nil, "absent means unchanged")
        #expect(delta.usage == AsyncTaskUsage(totalTokens: 1200, toolUses: 3, durationMs: 4500))
        #expect(delta.currentAgent == "", "Grok's empty string is a value")
    }

    @Test func aSpawnCarriesTheTasksIdentity() throws {
        let decoded = try event(#"""
        {"type":"async_task","delta":{"task_id":"autonomous-turn-1","spawned":true,"name":"Claude is working",
         "task_type":"turn","description":"A scheduled task fired.","show_in_transcript":false,"can_stop":true}}
        """#)
        guard case .asyncTask(let delta) = decoded else { Issue.record("decoded \(decoded)"); return }
        let row = AsyncTasks.record(from: delta)
        #expect(row.taskType == AsyncTasks.autonomousTurnTaskType)
        #expect(row.canStop)
        #expect(row.state == "running")
    }

    @Test func aDeltaWithoutAnIdIsNotATaskEvent() throws {
        if case .asyncTask = try event(#"{"type":"async_task","delta":{"spawned":true}}"#) {
            Issue.record("a nameless delta must not decode as a task")
        }
    }

    @Test func backgroundActivityCarriesTheWholeOutstandingSet() throws {
        let decoded = try event(#"""
        {"type":"background_activity","session_id":"s1","outstanding":2,"watermark":10,
         "outstanding_tasks":[
           {"task_id":"a1","kind":"agent","tool_use_id":"toolu_1","description":"Survey","started_at_ms":1700000000000},
           {"task_id":"b1","kind":"shell","started_at_ms":5}],
         "turns":[{"id":"bg-1","role":"assistant","blocks":[]}]}
        """#)
        guard case .backgroundActivity(let tasks, _) = decoded else { Issue.record("decoded \(decoded)"); return }
        #expect(tasks.map(\.taskId) == ["a1", "b1"])
        #expect(tasks[0].toolUseId == "toolu_1")
        #expect(tasks[0].startedAtMs == 1_700_000_000_000)
        #expect(tasks[1].kind == "shell")
        #expect(tasks[1].toolUseId == nil)
        guard case .backgroundActivity(_, let outOfTurn) = decoded else { return }
        #expect(outOfTurn.turnCount == 1)
        // A turn without its timestamp is not one this build can place: counted, not kept.
        #expect(outOfTurn.turns.isEmpty)
        #expect(outOfTurn.settled.isEmpty)

        let settled = try event(#"""
        {"type":"background_activity","session_id":"s1","outstanding":0,"watermark":12,
         "settled":[{"task_id":"a1","status":"completed","summary":"Survey done","tool_use_id":"toolu_1"},
                    {"task_id":"a2","status":"completed","interim":true},{"status":"completed"}]}
        """#)
        guard case .backgroundActivity(let rest, let batch) = settled else { Issue.record("decoded \(settled)"); return }
        #expect(rest.isEmpty)
        #expect(batch.turnCount == 0)
        #expect(batch.settled == [BackgroundSettled(taskId: "a1", status: "completed", summary: "Survey done",
                                                    toolUseId: "toolu_1"),
                                  BackgroundSettled(taskId: "a2", status: "completed", interim: true)])
        #expect(batch.watermark == 12)
        #expect(batch.sessionID == "s1")

        // Absent on the wire = none.
        guard case .backgroundActivity(let none, _) = try event(#"{"type":"background_activity","outstanding":0}"#) else {
            Issue.record("expected background activity"); return
        }
        #expect(none.isEmpty)
    }

    @Test func delegationEventsDecode() throws {
        let started = try event(#"""
        {"type":"delegation_started","parent_connection_id":"p","parent_tool_use_id":"call-1",
         "child_connection_id":"child-a","child_conversation_id":42,"agent_type":"codex",
         "task_preview":"fix the build","task_id":"task-9","assistant_name":"Reviewer","assistant_id":3}
        """#)
        guard case .delegationStarted(let info) = started else { Issue.record("decoded \(started)"); return }
        #expect(info.parentToolUseId == "call-1")
        #expect(info.childConnectionId == "child-a")
        #expect(info.childConversationId == 42)
        #expect(info.agentType == .codex)
        #expect(info.taskPreview == "fix the build")
        #expect(info.taskId == "task-9")
        #expect(info.assistantName == "Reviewer")
        #expect(info.assistantId == 3)

        let ok = try event(#"""
        {"type":"delegation_completed","parent_connection_id":"p","parent_tool_use_id":"call-1",
         "child_connection_id":"child-a","child_conversation_id":42,"agent_type":"codex",
         "result":{"kind":"ok","duration_ms":10}}
        """#)
        guard case .delegationCompleted(_, let succeeded, let code) = ok else { Issue.record("decoded \(ok)"); return }
        #expect(succeeded)
        #expect(code == nil)

        let err = try event(#"""
        {"type":"delegation_completed","parent_tool_use_id":"call-1","child_connection_id":"child-a",
         "child_conversation_id":42,"agent_type":"custom:my-agent","result":{"kind":"err","error_code":"timeout"}}
        """#)
        guard case .delegationCompleted(let info2, let succeeded2, let code2) = err else {
            Issue.record("decoded \(err)"); return
        }
        #expect(!succeeded2)
        #expect(code2 == "timeout")
        #expect(info2.agentType == .other(wire: "custom:my-agent"))

        let running = try event(#"{"type":"delegation_child_running","child_connection_id":"child-a","running":true}"#)
        guard case .delegationChildRunning(let child, let isRunning) = running else {
            Issue.record("decoded \(running)"); return
        }
        #expect(child == "child-a")
        #expect(isRunning)
    }

    @Test func aPromptSuggestionOrItsWithdrawalDecodes() throws {
        guard case .promptSuggestion(let text) = try event(#"{"type":"prompt_suggestion","text":"Run the tests"}"#) else {
            Issue.record("expected a suggestion"); return
        }
        #expect(text == "Run the tests")
        guard case .promptSuggestion(let none) = try event(#"{"type":"prompt_suggestion","text":null}"#) else {
            Issue.record("expected a withdrawal"); return
        }
        #expect(none == nil)
    }

    @Test func anEnvelopeCarriesTheseLikeAnyOther() throws {
        let envelope = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(#"""
        {"seq":77,"connection_id":"c1","type":"prompt_suggestion","text":"commit this"}
        """#.utf8))
        #expect(envelope.seq == 77)
        guard case .promptSuggestion(let text) = envelope.event else {
            Issue.record("decoded \(envelope.event)"); return
        }
        #expect(text == "commit this")
    }

    @Test func unknownTypesStillFallThrough() throws {
        guard case .unknown(let type) = try event(#"{"type":"tab_title_changed","title":null}"#) else {
            Issue.record("expected unknown"); return
        }
        #expect(type == "tab_title_changed")
    }
}

@Suite struct RunsSnapshotDecodingTests {
    @Test func theSnapshotRestatesTheRunningListAndTheSuggestion() throws {
        let snap = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(#"""
        {"connection_id":"c1","status":"connected","external_id":"s1","event_seq":12,
         "async_tasks":[{"task_id":"t1","name":"pnpm test","task_type":"shell","description":"",
                         "show_in_transcript":true,"can_stop":true,"state":"completed","summary":"ok"}],
         "background_outstanding_tasks":[{"task_id":"a1","kind":"agent","started_at_ms":9}],
         "delegated_children":["child-a"],
         "active_delegations":[{"parent_tool_use_id":"call-1","child_connection_id":"child-a",
                                "child_conversation_id":4,"agent_type":"claude_code"}],
         "prompt_suggestion":"Run the tests"}
        """#.utf8))
        #expect(snap.runs.asyncTasks.map(\.state) == ["completed"])
        #expect(snap.runs.asyncTasks.first?.summary == "ok")
        #expect(snap.runs.backgroundOutstandingTasks.map(\.taskId) == ["a1"])
        #expect(snap.runs.delegatedChildren == ["child-a"])
        #expect(snap.runs.activeDelegations.first?.agentType == .claudeCode)
        #expect(snap.runs.activeDelegations.first?.taskPreview == nil, "an older row has no task")
        #expect(snap.runs.promptSuggestion == "Run the tests")
    }

    @Test func everyFieldIsOmittedWhenEmpty() throws {
        let snap = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(#"{"status":"connected"}"#.utf8))
        #expect(snap.runs == .empty)
    }

    @Test func aMisshapenFieldCostsOnlyItself() throws {
        let snap = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(#"""
        {"status":"prompting","async_tasks":{"not":"an array"},"delegated_children":["child-a"],
         "prompt_suggestion":42}
        """#.utf8))
        #expect(snap.status == .prompting)
        #expect(snap.runs.asyncTasks.isEmpty)
        #expect(snap.runs.delegatedChildren == ["child-a"])
        #expect(snap.runs.promptSuggestion == nil)
    }

    @Test func theHttpSnapshotCarriesThemToo() throws {
        let snap = try CodegJSON.decoder.decode(SessionSnapshot.self, from: Data(#"""
        {"selectors_ready":true,"prompt_suggestion":"commit this","delegated_children":["x"]}
        """#.utf8))
        #expect(snap.runs.promptSuggestion == "commit this")
        #expect(snap.runs.delegatedChildren == ["x"])
    }
}
