import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/group.test.ts` (codeg 0.44).
@MainActor
struct ActivityGroupTests {
    private func tool(_ id: String, _ toolName: String, _ input: String,
                      state: ToolCallState = .done, output: String? = "ok") -> ActivityStep {
        let part = ToolCallVM(id: id, rawName: toolName, kind: "", state: state, input: input,
                              output: output, content: nil, isError: state == .error)
        return .tool(ActivityToolStep(key: "tool:\(id)", call: part, tool: DescribeToolCall.describe(part)))
    }

    private func read(_ id: String) -> ActivityStep { tool(id, "Read", #"{"file_path":"/r/\#(id).ts"}"#) }
    private func grep(_ id: String) -> ActivityStep { tool(id, "Grep", #"{"pattern":"\#(id)"}"#) }
    private func bash(_ id: String, state: ToolCallState = .done, output: String? = "ok") -> ActivityStep {
        tool(id, "Bash", #"{"command":"echo \#(id)"}"#, state: state, output: output)
    }

    private func thought(_ id: String, streaming: Bool = false) -> ActivityStep {
        .thought(key: "thought:\(id)", text: .settled(id), streaming: streaming)
    }

    private func note(_ id: String) -> ActivityStep { .note(key: "note:\(id)", .text(.settled(id))) }

    /// Compact picture of the rows: `explore[a,b]`, `step:x`.
    private func shape(_ items: [ActivityItem]) -> [String] {
        func id(_ key: String) -> String { String(key.split(separator: ":", omittingEmptySubsequences: false)[1]) }
        return items.map { item in
            switch item {
            case .group(_, let kind, let steps, _):
                return "\(kind.rawValue)[\(steps.map { id($0.key) }.joined(separator: ","))]"
            case .step(let step):
                return "step:\(id(step.key))"
            }
        }
    }

    private func groupStatus(_ item: ActivityItem?) -> StepStatus? {
        if case .group(_, _, _, let status)? = item { return status }
        return nil
    }

    @Test("folds a run of exploration into one row")
    func foldsARunOfExplorationIntoOneRow() {
        let items = ActivityGroup.items([read("a"), read("b"), grep("c")])
        #expect(shape(items) == ["explore[a,b,c]"])
        #expect(items.first?.key == "tool:a")
        #expect(groupStatus(items.first) == .succeeded)
    }

    @Test("leaves a lone call as a plain row")
    func leavesALoneCallAsAPlainRow() {
        #expect(shape(ActivityGroup.items([read("a"), bash("b")])) == ["step:a", "step:b"])
    }

    @Test("lets a thought between two exploration calls stand on its own")
    func letsAThoughtBetweenTwoExplorationCallsStandOnItsOwn() {
        #expect(shape(ActivityGroup.items([
            thought("t0"), read("a"), read("b"), thought("t1"), read("c"), grep("d"),
            thought("t2", streaming: true), read("e"),
        ])) == ["step:t0", "explore[a,b]", "step:t1", "explore[c,d]", "step:t2", "step:e"])
    }

    @Test("keeps a thought that no call followed after its run")
    func keepsAThoughtThatNoCallFollowedAfterItsRun() {
        #expect(shape(ActivityGroup.items([read("a"), read("b"), thought("t1"), bash("c")]))
            == ["explore[a,b]", "step:t1", "step:c"])
    }

    @Test("folds commands, and lets a thought split them")
    func foldsCommandsAndLetsAThoughtSplitThem() {
        #expect(shape(ActivityGroup.items([bash("a"), bash("b"), thought("t"), bash("c")]))
            == ["command[a,b]", "step:t", "step:c"])
    }

    @Test("ends a run at prose, edits and other tools")
    func endsARunAtProseEditsAndOtherTools() {
        let edit = tool("e", "Edit", #"{"file_path":"/r/x.ts","old_string":"a","new_string":"b"}"#)
        let mcp = tool("m", "mcp__linear__get_issue", #"{"id":"1"}"#)
        #expect(shape(ActivityGroup.items([read("a"), note("n"), read("b"), edit, read("c"), mcp, read("d")]))
            == ["step:a", "step:n", "step:b", "step:e", "step:c", "step:m", "step:d"])
    }

    @Test("keeps a failure inside its group and marks the group failed")
    func keepsAFailureInsideItsGroupAndMarksTheGroupFailed() {
        let items = ActivityGroup.items([bash("a"), bash("b", state: .error, output: "Exit code 1")])
        #expect(shape(items) == ["command[a,b]"])
        #expect(groupStatus(items.first) == .failed)
    }

    @Test("marks a group with a live member running")
    func marksAGroupWithALiveMemberRunning() {
        let items = ActivityGroup.items([bash("a"), bash("b", state: .running, output: nil)])
        #expect(groupStatus(items.first) == .running)
    }
}
