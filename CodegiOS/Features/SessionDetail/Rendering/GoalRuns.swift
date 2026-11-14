import Foundation

/// A Codex `/goal` run: `create_goal` starts it, every part until the closing
/// `update_goal` belongs to it (web `AdaptedGoalRunPart`).
struct GoalRunPart {
    var start: ToolCallVM
    /// Nil while the goal is still open — and for good once codex leaves it
    /// open, which it does when a turn ends or is interrupted.
    var end: ToolCallVM?
    /// The run's own parts, in order. Neither goal call is among them.
    var items: [RenderPart]
    /// Draws as working: an unfinished run only while its reply streams.
    var isRunning: Bool
}

/// Wraps Codex `/goal` lifecycles into goal runs — port of the web adapter's
/// `groupGoalRuns` and its helpers (`ai-elements-adapter.ts`, codeg 0.44).
///
/// Runs after the poll lanes are grouped, so a run's items can hold them.
/// The web groups each persisted turn and then again across the turns of a
/// reply (`mergeRunParts`); iOS merges a reply's turns before adapting
/// (`TranscriptTimeline.merge`), so one pass over the merged reply covers
/// runs that cross turns. The goal-run arms below — a run handed in already
/// grouped — are kept so the grouping stays the web's, whole.
///
/// Not ported: the web's `Goal updated (<status>): …` markers in assistant
/// PROSE (`expandGoalUpdateText`) and the objective hints that feed it. A live
/// run's prose is never read while the timeline is assembled.
@MainActor
enum GoalRuns {
    /// `create_goal`, under any wrapper (`functions.`, `mcp__…__`, a live title).
    static func startCall(_ part: RenderPart) -> ToolCallVM? {
        guard case .tool(let vm) = part,
              ToolNameNormalizer.normalizeToolName(vm.toolName) == "create_goal" else { return nil }
        return vm
    }

    static func endCall(_ part: RenderPart) -> ToolCallVM? {
        guard case .tool(let vm) = part,
              ToolNameNormalizer.normalizeToolName(vm.toolName) == "update_goal" else { return nil }
        return vm
    }

    /// A call still being made (web `isRunningToolCall`).
    static func isRunningCall(_ vm: ToolCallVM) -> Bool {
        vm.state == .inputStreaming || vm.state == .running
    }

    /// The key a goal's objective is written under, as it reads in JSON.
    private static let objectiveJSONKey = "\"objective\""

    /// The objective a goal call names: its result's `goal.objective`, else its
    /// own `objective` argument (web `goalObjectiveKeyFromTool`).
    static func objectiveKey(of call: ToolCallVM) -> String? {
        // Every call of a reply can pass through here while it streams: parse
        // only what can name an objective at all.
        func parsed(_ raw: String?) -> [String: Any]? {
            guard let raw, raw.contains(objectiveJSONKey) else { return nil }
            return ActivityJSON.tryParse(raw)
        }
        let input = parsed(call.input)
        let output = parsed(call.output)
        return ActivityGoal.nonBlankString(output?["goal"] as? [String: Any], "objective")
            ?? ActivityGoal.nonBlankString(input, "objective")
    }

    /// A run's objective: its closing call's, else its opening call's.
    static func objectiveKey(ofRun run: GoalRunPart) -> String? {
        run.end.flatMap { objectiveKey(of: $0) } ?? objectiveKey(of: run.start)
    }

    private struct Active {
        var start: ToolCallVM
        var items: [RenderPart]
    }

    /// Wrap each `create_goal` … `update_goal` lifecycle into one goal run.
    ///
    /// codex keeps a `/goal` active across turns and does NOT emit a closing
    /// `update_goal` when a turn ends or is interrupted, so an unfinished run
    /// is running only while `isStreaming` — a stopped or reloaded one settles.
    /// A settled run folds to its header, so one that never closed hands the
    /// prose after its last process part back to the reply (a reload still
    /// shows the answer under the row); a live run keeps it, and opens.
    ///
    /// A run that closed remembers its objective: a later `create_goal` (or an
    /// unfinished run) for the same objective is stale — codex re-announcing a
    /// goal it already finished — and is not drawn as a run again.
    static func group(_ parts: [RenderPart], isStreaming: Bool = false) -> [RenderPart] {
        var result: [RenderPart] = []
        var active: Active?
        var completedObjectives = Set<String>()

        func rememberCompleted(_ start: ToolCallVM, _ end: ToolCallVM?) {
            if let objective = end.flatMap({ objectiveKey(of: $0) }) ?? objectiveKey(of: start) {
                completedObjectives.insert(objective)
            }
        }

        func isStaleStart(_ call: ToolCallVM) -> Bool {
            guard let objective = objectiveKey(of: call) else { return false }
            return completedObjectives.contains(objective)
        }

        func push(_ start: ToolCallVM, _ end: ToolCallVM?, _ items: [RenderPart], _ isRunning: Bool) {
            // Only a run that never closed lifts its trailing answer: after a
            // closing `update_goal` later prose is already outside the run,
            // and mid-run notes stay where they were written.
            guard !isRunning, end == nil else {
                result.append(.goalRun(GoalRunPart(start: start, end: end, items: items, isRunning: isRunning)))
                return
            }
            let split = BuildActivity.splitTrailingAnswer(items)
            result.append(.goalRun(GoalRunPart(start: start, end: nil, items: split.body, isRunning: false)))
            result.append(contentsOf: split.trailing)
        }

        func flushActive() {
            guard let current = active else { return }
            push(current.start, nil, current.items, isStreaming)
            active = nil
        }

        for part in parts {
            if case .goalRun(let run) = part {
                let isStaleUnfinished: Bool = {
                    guard run.end == nil, let objective = objectiveKey(ofRun: run) else { return false }
                    return completedObjectives.contains(objective)
                }()
                guard let current = active else {
                    if isStaleUnfinished {
                        result.append(contentsOf: run.items)
                    } else if run.end == nil {
                        active = Active(start: run.start, items: run.items)
                    } else {
                        push(run.start, run.end, run.items, run.isRunning)
                        rememberCompleted(run.start, run.end)
                    }
                    continue
                }
                if isStaleUnfinished {
                    active?.items.append(contentsOf: run.items)
                    continue
                }
                if let end = run.end {
                    push(run.start, end, current.items + run.items, run.isRunning)
                    rememberCompleted(run.start, end)
                    active = nil
                } else {
                    active = Active(start: run.start, items: current.items + run.items)
                }
                continue
            }

            if let start = startCall(part) {
                if active == nil, isStaleStart(start) { continue }
                if active != nil {
                    // A goal set again mid-run: the run goes on under it.
                    active?.start = start
                    continue
                }
                flushActive()
                active = Active(start: start, items: [])
                continue
            }

            if let current = active, let end = endCall(part) {
                push(current.start, end, current.items, isRunningCall(end))
                rememberCompleted(current.start, end)
                active = nil
                continue
            }

            if active != nil {
                active?.items.append(part)
            } else {
                result.append(part)
            }
        }

        flushActive()
        return result
    }
}
