import Foundation

/// The counts behind a reply's activity header — port of the web's
/// `src/lib/activity/summarize.ts` and `delegation-task.ts` (codeg 0.44).
///
/// - Reads and edits count distinct files; searches, commands, sub-agents
///   (delegations included), MCP calls and web lookups count calls.
/// - A grep that matched nothing is not a failure (it already settles as a
///   success), and a call the user interrupted counts as interrupted.
/// - A failure is "recovered" when a later step of the same kind on the same
///   target succeeded: the same command line, the same file, the same MCP tool
///   with the same arguments.
///
/// Not ported yet: the web's background-task rows (Claude Code `TaskOutput`
/// polls), which iOS does not group into a lane of their own.
enum ActivitySummarize {
    /// What "the same thing" means for the recovery rule, or nil when a step
    /// of this kind is never considered retried.
    static func retrySignature(_ tool: ToolDescriptor, input: String?) -> String? {
        func squash(_ s: String) -> String {
            s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        func stripped(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        }
        switch tool.kind {
        case .command, .script:
            let command = squash(tool.command?.display ?? "")
            return command.isEmpty ? nil : "command:\(command)"
        case .monitor:
            let watched = squash(tool.command?.display ?? "")
            return watched.isEmpty ? nil : "monitor:\(watched)"
        case .network:
            return tool.target.map { "network:\($0.full ?? $0.text)" }
        case .edit:
            let paths = (tool.files ?? []).map(\.path).sorted()
            return paths.isEmpty ? nil : "edit:\(paths.joined(separator: "\n"))"
        case .mcp:
            return tool.mcp.map { "mcp:\($0.server)/\($0.tool):\(stripped(input))" }
        case .read, .search, .glob, .list, .fetch, .webSearch:
            return tool.target.map { "\(tool.kind.rawValue):\($0.path ?? $0.full ?? $0.text)" }
        case .generic:
            return "generic:\(tool.toolName):\(stripped(input))"
        default:
            return nil
        }
    }

    static func summarize(_ steps: [ActivityStep]) -> ActivitySummary {
        var summary = ActivitySummary()
        var readPaths = Set<String>()
        var editPaths = Set<String>()
        var failures: [(key: String, signature: String?, index: Int)] = []
        var successes: [String: Int] = [:]

        for (index, step) in steps.enumerated() {
            switch step {
            case .delegationPolls(_, _, let status):
                if status.isLive { summary.running = true }
                continue
            case .thought(_, _, let streaming):
                if streaming { summary.running = true }
                continue
            case .taskList(_, let ops):
                // Bookkeeping, like the web's todo rows: not a step, but a live
                // op still means the reply is working.
                if ops.contains(where: { ActivityStatus.of($0).isLive }) { summary.running = true }
                continue
            case .compaction(_, _, _, let running):
                if running { summary.running = true }
                continue
            case .note, .image, .plan, .unsupported:
                continue
            case .tool(let toolStep):
                let tool = toolStep.tool
                if let later = toolStep.laterPolls {
                    // A delegation stands where its task's newest check says. A
                    // task that failed is the delegation's failure — counted
                    // once, on its row.
                    let taskId = delegationTaskId(toolStep)
                    let task = DelegationModel.buildTaskRows(later).first { $0.taskId == taskId }
                    switch task?.badge.status {
                    case .running?, .starting?: summary.running = true
                    case .err?: failures.append((step.key, nil, index))
                    default: break
                    }
                }
                if tool.status.isLive { summary.running = true }

                switch tool.kind {
                case .compaction, .todo, .delegationStatus, .shellSession:
                    break   // continuations and bookkeeping, not steps of their own
                default:
                    summary.steps += 1
                }

                switch tool.kind {
                case .command, .script:
                    summary.counts.commands += 1
                case .edit:
                    for file in tool.files ?? [] { editPaths.insert(file.path) }
                    if (tool.files ?? []).isEmpty { editPaths.insert(step.key) }
                case .agent, .collabAgent, .delegation, .delegationResume:
                    summary.counts.agents += 1
                case .mcp:
                    summary.counts.mcp += 1
                case .fetch, .webSearch:
                    summary.counts.web += 1
                case .read:
                    readPaths.insert(tool.target?.path ?? tool.target?.text ?? step.key)
                case .search, .glob, .list:
                    summary.counts.searches += 1
                default:
                    break
                }

                if tool.status == .cancelled {
                    summary.interrupted += 1
                    continue
                }
                let signature = retrySignature(tool, input: toolStep.call.input)
                if tool.status.isFailure {
                    failures.append((step.key, signature, index))
                } else if tool.status == .succeeded, let signature {
                    successes[signature] = index
                }
            }
        }

        summary.counts.readFiles = readPaths.count
        summary.counts.editedFiles = editPaths.count
        for failure in failures {
            if let signature = failure.signature, let later = successes[signature], later > failure.index {
                summary.recoveredKeys.insert(failure.key)
            } else if summary.firstUnrecoveredKey == nil {
                summary.firstUnrecoveredKey = failure.key
            }
        }
        summary.failed = failures.count
        summary.unrecovered = failures.count - summary.recoveredKeys.count
        return summary
    }

    /// The broker task a delegation step is about: a `delegate_to_agent`
    /// call's from its result, a `resume_delegation` call's from its `task_id`
    /// argument. Nil for any other step. (Web `delegationStepTaskId`; the web
    /// also drops a REFUSED resume, whose result iOS does not parse yet.)
    static func delegationTaskId(_ step: ActivityToolStep) -> String? {
        switch step.tool.kind {
        case .delegation:
            let pair = DelegationModel.outputError(step.call)
            return DelegationModel.parseDelegateTaskId(output: pair.output, errorText: pair.errorText)
        case .delegationResume:
            // The arguments, possibly inside an `{input|arguments: …}` envelope.
            return ActivityJSON.findStringFieldDeep(step.call.input, key: "task_id")
        default:
            return nil
        }
    }
}
