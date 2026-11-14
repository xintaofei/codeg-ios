import Foundation
import Testing
@testable import Codeg

/// Port of the web's `src/lib/async-tasks.test.ts` (codeg 0.44). "Returns the
/// same reference" becomes "returns an equal table": Swift arrays are values.
private func delta(_ id: String, _ spawned: Bool, name: String? = nil, taskType: String? = nil,
                   canStop: Bool? = nil, state: String? = nil, summary: String? = nil,
                   lastToolName: String? = nil, usage: AsyncTaskUsage? = nil,
                   outputFilePath: String? = nil, phase: String? = nil,
                   currentAgent: String? = nil) -> AsyncTaskDelta {
    AsyncTaskDelta(taskId: id, spawned: spawned, name: name, taskType: taskType, canStop: canStop,
                   state: state, summary: summary, lastToolName: lastToolName, usage: usage,
                   outputFilePath: outputFilePath, phase: phase, currentAgent: currentAgent)
}

private let spawn = AsyncTaskDelta(taskId: "t1", spawned: true, name: "pnpm test", taskType: "shell",
                                   description: "pnpm test --watch", showInTranscript: false, canStop: true)

private func record(_ id: String = "t1", state: String = "running", name: String = "pnpm test") -> AsyncTaskRecord {
    AsyncTaskRecord(taskId: id, name: name, taskType: "shell", description: "", showInTranscript: true,
                    canStop: true, state: state)
}

@Suite struct AsyncTaskUpsertTests {
    @Test func createsARowOnlyFromASpawnDelta() {
        // The spawn frame is the ONLY one carrying name/type/stop affordance, so
        // a progress delta for an id never announced means that frame was missed.
        #expect(AsyncTasks.upsert([], delta("ghost", false, state: "running")).isEmpty)

        let created = AsyncTasks.upsert([], spawn)
        #expect(created.count == 1)
        let row = created[0]
        #expect(row.taskId == "t1")
        #expect(row.name == "pnpm test")
        #expect(row.taskType == "shell")
        #expect(row.showInTranscript == false)
        #expect(row.canStop == true)
        // A spawn frame carries no state; the row starts live.
        #expect(row.state == "running")
    }

    @Test func changesNothingForAnUnknownProgressDelta() {
        let current = AsyncTasks.upsert([], spawn)
        #expect(AsyncTasks.upsert(current, delta("ghost", false)) == current)
        #expect(AsyncTasks.upsert(current, delta("", true, name: "nameless")) == current)
    }

    @Test func revisesOnlyTheFieldsADeltaCarries() {
        // Absent means UNCHANGED, never "clear it".
        var tasks = AsyncTasks.upsert([], spawn)
        tasks = AsyncTasks.upsert(tasks, delta(
            "t1", false, lastToolName: "Bash",
            usage: AsyncTaskUsage(totalTokens: 1200, toolUses: 3, durationMs: 4500),
            outputFilePath: "/tmp/tasks/t1.output"))
        #expect(tasks[0].name == "pnpm test")
        #expect(tasks[0].taskType == "shell")
        #expect(tasks[0].lastToolName == "Bash")
        #expect(tasks[0].outputFilePath == "/tmp/tasks/t1.output")
        #expect(tasks[0].usage?.totalTokens == 1200)
    }

    @Test func letsALateCorrectionReviseASettledTask() {
        // Retaining the row is what makes the correction a revision, not a resurrection.
        var tasks = AsyncTasks.upsert([], spawn)
        tasks = AsyncTasks.upsert(tasks, delta("t1", false, state: "stopped"))
        #expect(AsyncTasks.live(tasks).isEmpty)
        tasks = AsyncTasks.upsert(tasks, delta("t1", false, state: "completed", summary: "all green"))
        #expect(tasks.count == 1)
        #expect(tasks[0].state == "completed")
        #expect(tasks[0].summary == "all green")
        #expect(tasks[0].name == "pnpm test")
    }

    @Test func clearsAGrokWorkflowsAgentWithTheEmptyStringNotAbsence() {
        // Grok restates its whole run on every frame (each one a spawn); a
        // finished agent comes back as "" — absent would still mean unchanged.
        func frame(phase: String?, agent: String?) -> AsyncTaskDelta {
            delta("wf_1", true, name: "deep-research", taskType: "workflow", canStop: false,
                  state: "running", phase: phase, currentAgent: agent)
        }
        var tasks = AsyncTasks.upsert([], frame(phase: "Research", agent: "researcher-2"))
        #expect(tasks[0].phase == "Research")
        #expect(tasks[0].currentAgent == "researcher-2")
        tasks = AsyncTasks.upsert(tasks, frame(phase: "Verify", agent: ""))
        #expect(tasks.count == 1)
        #expect(tasks[0].phase == "Verify")
        #expect(tasks[0].currentAgent == "")
    }
}

@Suite struct AsyncTaskMergeTests {
    @Test func seedsRowsAClientAttachedTooLateToSeeAnnounced() {
        let merged = AsyncTasks.merge([], [record()])
        #expect(merged.map(\.taskId) == ["t1"])
    }

    @Test func replacesByIdRatherThanAppendingADuplicate() {
        // The snapshot is the BACKEND's merge of every delta, so it wins outright.
        let current = AsyncTasks.upsert([], spawn)
        var done = current[0]
        done.state = "completed"
        let merged = AsyncTasks.merge(current, [done])
        #expect(merged.count == 1)
        #expect(merged[0].state == "completed")
    }

    @Test func changesNothingForAnEmptyOrAbsentTable() {
        let current = AsyncTasks.upsert([], spawn)
        #expect(AsyncTasks.merge(current, []) == current)
        #expect(AsyncTasks.merge(current, nil) == current)
    }
}

@Suite struct AsyncTaskAdoptUnknownTests {
    @Test func neverWalksAFinishedTaskBackToRunning() {
        // The client applied the terminal delta at seq 11; the snapshot was taken
        // at seq 10 and still says running. Its correction is never replayed.
        let live = AsyncTasks.upsert(AsyncTasks.upsert([], spawn),
                                     delta("t1", false, state: "completed", summary: "all green"))
        var stale = live[0]
        stale.state = "running"
        let adopted = AsyncTasks.adoptUnknown(live, [stale])
        #expect(adopted == live)
        #expect(adopted[0].state == "completed")
        #expect(adopted[0].summary == "all green")
    }

    @Test func stillAdoptsIdsTheClientNeverSawAnnounced() {
        let live = AsyncTasks.upsert([], spawn)
        var stale = live[0]
        stale.state = "running"
        var other = live[0]
        other.taskId = "t2"
        other.name = "deploy watch"
        let adopted = AsyncTasks.adoptUnknown(live, [stale, other])
        #expect(adopted.count == 2)
        #expect(adopted[1].taskId == "t2")
        #expect(adopted[0] == live[0])
    }

    @Test func changesNothingForAnEmptyOrAbsentTable() {
        let current = AsyncTasks.upsert([], spawn)
        #expect(AsyncTasks.adoptUnknown(current, []) == current)
        #expect(AsyncTasks.adoptUnknown(current, nil) == current)
    }
}

@Suite struct AsyncTaskLiveTests {
    @Test func showsRunningAndPausedHidesTheTerminalThree() {
        let rows = ["running", "paused", "completed", "failed", "stopped"].enumerated().map {
            record("t\($0.offset)", state: $0.element)
        }
        #expect(AsyncTasks.live(rows).map(\.state) == ["running", "paused"])
        // An unrecognized future state counts as LIVE.
        #expect(AsyncTasks.live([record(state: "throttled")]).count == 1)
        #expect(!AsyncTasks.isTerminal(record(state: "throttled")))
    }
}

@Suite struct AutonomousTurnCauseTests {
    @Test func readsClaudeAgentAcpsFixedDescriptions() {
        #expect(AsyncTasks.autonomousTurnCause("Claude Code started a turn without a prompt.") == .unknown)
        #expect(AsyncTasks.autonomousTurnCause("A scheduled task fired.") == .scheduledTask)
        #expect(AsyncTasks.autonomousTurnCause("A scheduled wakeup fired.") == .scheduledWakeup(at: nil))
        #expect(AsyncTasks.autonomousTurnCause("A scheduled wakeup fired (set for 2026-10-26T14:30:00.000Z).")
                == .scheduledWakeup(at: Date(timeIntervalSince1970: 1_793_025_000)))
    }

    @Test func passesClaudeCodesOwnWordsThrough() {
        let summary = #"Background command "pnpm build" completed (exit code 0)"#
        #expect(AsyncTasks.autonomousTurnCause(summary) == .text(summary))
        // A wakeup time that does not parse keeps the wakeup, without a time.
        #expect(AsyncTasks.autonomousTurnCause("A scheduled wakeup fired (set for soon).") == .scheduledWakeup(at: nil))
        #expect(AsyncTasks.autonomousTurnCause("   ") == .unknown)
    }

    @Test func matchesTheFixedSentencesAfterTrimming() {
        #expect(AsyncTasks.autonomousTurnCause("  A scheduled task fired.\n") == .scheduledTask)
        // No time at all between the parentheses is not the timed sentence.
        #expect(AsyncTasks.autonomousTurnCause("A scheduled wakeup fired (set for ).")
                == .text("A scheduled wakeup fired (set for )."))
    }

    @Test func rendersTheCauseForTheRow() {
        #expect(LiveRunsText.turnCause("Claude Code started a turn without a prompt.") == nil)
        #expect(LiveRunsText.turnCause("Background job finished") == "Background job finished")
        #expect(LiveRunsText.turnCause("A scheduled task fired.") != nil)
    }
}
