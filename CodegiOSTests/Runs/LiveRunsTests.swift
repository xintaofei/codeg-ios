import Foundation
import Testing
@testable import Codeg

/// Port of the web's `src/lib/live-runs.test.ts` (codeg 0.44), without the
/// foreground sub-agents: iOS draws the streaming reply's own sub-agent calls
/// in the live timeline, not in the running list. `runningSubAgentCalls` /
/// `subAgentCallsById` have no counterpart for the same reason.
private func task(_ id: String = "t1", state: String = "running") -> AsyncTaskRecord {
    AsyncTaskRecord(taskId: id, name: "pnpm test", taskType: "shell", description: "",
                    showInTranscript: false, canStop: true, state: state)
}

private func background(_ id: String = "a1", kind: String = "agent", toolUseId: String? = "toolu_1",
                        description: String? = "Survey the runners", startedAtMs: Int64 = 1_000) -> BackgroundOutstandingTask {
    BackgroundOutstandingTask(taskId: id, kind: kind, toolUseId: toolUseId, description: description,
                              startedAtMs: startedAtMs)
}

private func binding(_ child: String, _ status: DelegationBinding.Status = .running,
                     parent: String? = nil) -> DelegationBinding {
    DelegationBinding(
        info: DelegationInfo(parentToolUseId: parent ?? "call-\(child)", childConnectionId: child,
                             childConversationId: 7, agentType: .codex),
        status: status, errorCode: nil)
}

private func collect(asyncTasks: [AsyncTaskRecord] = [], backgroundTasks: [BackgroundOutstandingTask] = [],
                     delegatedChildren: [String] = [], bindings: [DelegationBinding] = []) -> LiveRuns {
    LiveRuns.collect(asyncTasks: asyncTasks, backgroundTasks: backgroundTasks,
                     delegatedChildren: delegatedChildren, delegationBindings: bindings)
}

@Suite struct CollectLiveRunsTests {
    @Test func isEmptyCountAndAllWhenNothingRuns() {
        #expect(collect() == .empty)
    }

    @Test func listsTheBackgroundTasksStillRunningOrPausedNotTheSettled() {
        let runs = collect(asyncTasks: [
            task("run"), task("paused", state: "paused"), task("done", state: "completed"),
            task("failed", state: "failed"), task("stopped", state: "stopped"),
        ])
        #expect(runs.tasks.map(\.taskId) == ["run", "paused"])
        #expect(runs.count == 2)
    }

    @Test func listsTheBackgroundSubAgentsItsProducerStillCounts() {
        let runs = collect(backgroundTasks: [background()])
        #expect(runs.subagents == [LiveRuns.SubAgentRun(
            key: "bg:a1", toolUseId: "toolu_1", description: "Survey the runners", startedAtMs: 1_000)])
        #expect(runs.count == 1)
    }

    @Test func leavesBackgroundShellsToTheTaskTableWhichCanStopThem() {
        let runs = collect(backgroundTasks: [background("shell", kind: "shell", toolUseId: nil)])
        #expect(runs.subagents.isEmpty)
        #expect(runs.count == 0)
    }

    @Test func keepsABackgroundSubAgentWithNoLaunchCallTitledByItsProducer() {
        let runs = collect(backgroundTasks: [background(toolUseId: nil)])
        #expect(runs.subagents.first?.toolUseId == nil)
        #expect(runs.subagents.first?.description == "Survey the runners")
    }

    @Test func listsASubAgentOnceEvenWhenTwoEntriesNameItsCall() {
        let runs = collect(backgroundTasks: [background("a1"), background("a2")])
        #expect(runs.subagents.map(\.key) == ["bg:a1"])
    }

    @Test func dropsAStartTimeTheProducerNeverGave() {
        #expect(collect(backgroundTasks: [background(startedAtMs: 0)]).subagents.first?.startedAtMs == nil)
    }

    @Test func takesWhichDelegationsRunFromTheChildrenWhoTheyAreFromTheBindings() {
        let runs = collect(delegatedChildren: ["child-a", "child-b"], bindings: [binding("child-a")])
        #expect(runs.delegations == [
            LiveRuns.DelegationRun(childConnectionId: "child-a", binding: binding("child-a")),
            // Its call never got a card: listed bare rather than not at all.
            LiveRuns.DelegationRun(childConnectionId: "child-b", binding: nil),
        ])
        #expect(runs.count == 2)
    }

    @Test func dropsABindingStillMarkedRunningOnceTheParentNoLongerListsItsChild() {
        // A missed completion event would otherwise keep it "running" forever.
        #expect(collect(bindings: [binding("child-a")]).delegations.isEmpty)
    }

    @Test func leavesOutAChildWhoseCompletionIsAlreadyIn() {
        #expect(collect(delegatedChildren: ["child-a"], bindings: [binding("child-a", .ok)]).delegations.isEmpty)
    }

    @Test func speaksForAResumedChildThroughItsRunningBinding() {
        let finished = binding("child-a", .ok, parent: "call-first")
        let resumed = binding("child-a", .running, parent: "call-again")
        let runs = collect(delegatedChildren: ["child-a"], bindings: [resumed, finished])
        #expect(runs.delegations == [LiveRuns.DelegationRun(childConnectionId: "child-a", binding: resumed)])
    }

    @Test func listsAChildOnceEvenIfNamedTwice() {
        #expect(collect(delegatedChildren: ["child-a", "child-a"]).delegations.count == 1)
    }

    @Test func countsEveryRowItLists() {
        let runs = collect(asyncTasks: [task()], backgroundTasks: [background()], delegatedChildren: ["child-a"])
        #expect(runs.count == runs.tasks.count + runs.subagents.count + runs.delegations.count)
        #expect(runs.count == 3)
    }
}

@Suite struct LiveRunsFormattingTests {
    @Test func formatsTokenCountsLikeTheWeb() {
        #expect(LiveRuns.formatTokenCount(512) == "512")
        #expect(LiveRuns.formatTokenCount(1_000) == "1K")
        #expect(LiveRuns.formatTokenCount(1_200) == "1.2K")
        #expect(LiveRuns.formatTokenCount(3_500_000) == "3.5M")
        #expect(LiveRuns.formatTokenCount(2_000_000) == "2M")
    }
}
