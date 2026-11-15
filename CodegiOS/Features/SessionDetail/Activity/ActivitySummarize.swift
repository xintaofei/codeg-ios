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
/// - A background task is one step however often it was polled, and its
///   failure is one failure, which nothing recovers.
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

    /// Every step, with goal runs opened up into the steps they contain: a
    /// goal's work counts as the reply's, its own two calls not at all.
    static func flatten(_ steps: [ActivityStep]) -> [ActivityStep] {
        var out: [ActivityStep] = []
        for step in steps {
            if case .goal(let goal) = step {
                out.append(contentsOf: flatten(goal.model.steps))
            } else {
                out.append(step)
            }
        }
        return out
    }

    /// - Parameter delegation: how a delegation step's card stands, read at
    ///   draw time against what the connection knows (its live binding, the
    ///   thread's newest check on the task). When it answers, the delegation
    ///   counts as running or failed by that — what its card says — instead
    ///   of by the call and the checks in this reply alone, which a child
    ///   that finished after the reply settled leaves behind.
    static func summarize(_ steps: [ActivityStep],
                          delegation: ((ActivityToolStep) -> DelegationCardStatus?)? = nil) -> ActivitySummary {
        var summary = ActivitySummary()
        var readPaths = Set<String>()
        var editPaths = Set<String>()
        var failures: [(key: String, signature: String?, index: Int)] = []
        var successes: [String: Int] = [:]

        for (index, step) in flatten(steps).enumerated() {
            switch step {
            case .backgroundTasks(let tasks):
                for row in tasks.rows {
                    summary.steps += 1
                    if row.badge == .running { summary.running = true }
                    if row.badge == .failed { failures.append((step.key, nil, index)) }
                }
                continue
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
            case .compaction(_, let info):
                // Not a step of its own (web: a continuation), but a failed one
                // is a failure of the reply's — counted, and what "N failed"
                // opens the reply at, so a folded reply doesn't hide it.
                if info.running { summary.running = true }
                if info.failed { failures.append((step.key, nil, index)) }
                continue
            case .note, .image, .plan, .unsupported:
                continue
            case .goal:
                continue   // opened up by `flatten`
            case .tool(let toolStep):
                let tool = toolStep.tool
                let card = tool.kind == .delegation || tool.kind == .delegationResume
                    ? delegation?(toolStep) : nil
                if let card {
                    switch card {
                    case .running, .starting, .waiting: summary.running = true
                    case .err: failures.append((step.key, nil, index))
                    case .ok: break
                    }
                } else if let later = toolStep.laterPolls {
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
                if card == nil, tool.status.isLive { summary.running = true }

                switch tool.kind {
                case .compaction, .todo, .delegationStatus, .shellSession:
                    break   // continuations and bookkeeping, not steps of their own
                default:
                    // An orphan result (iOS makes it a call named "result" with
                    // no input) is the web's `tool-result` part, which is no step.
                    if !(toolStep.call.rawName == "result" && toolStep.call.input == nil) {
                        summary.steps += 1
                    }
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

                // Its card already said how it stands.
                if card != nil { continue }
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
    /// call's from its result (else the meta the broker stamped on it), a
    /// `resume_delegation` call's from its `task_id` argument — unless the
    /// resume was refused. Nil for any other step. (Web `delegationStepTaskId`.)
    static func delegationTaskId(_ step: ActivityToolStep) -> String? {
        switch step.tool.kind {
        case .delegation:
            return DelegationModel.delegateCallTaskId(step.call)
        case .delegationResume:
            // A refused resume started no run: it is about no task's progress,
            // so the checks after it stay with the call before it.
            if DelegationModel.isRefusedResume(step.call) { return nil }
            // The arguments, possibly inside an `{input|arguments: …}` envelope.
            return ActivityJSON.findStringFieldDeep(step.call.input, key: "task_id")
        default:
            return nil
        }
    }
}
