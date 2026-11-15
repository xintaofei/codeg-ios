import Foundation

/// A codeg delegation as its card and its rail marker draw it (web
/// `DelegationCardModel` / `useDelegationCardModel`): who took the task, how it
/// stands, and the child session to open. Resolved once from the call, the
/// connection's live binding and the newest check on the task, so the card and
/// its marker never disagree.
struct DelegationCard: Equatable {
    var status: DelegationCardStatus
    /// The agent that runs (ran) the task; nil draws the generic sub-agent.
    var agentType: AgentType?
    /// The assistant the task ran as, when it ran as one.
    var assistantName: String?
    var task: String?
    var taskId: String?
    var workingDir: String?
    var errorCode: String?
    var childConversationId: Int?
    var durationMs: Double?
    /// What the task came back with, once it ended.
    var outcome: String?
    var progress: DelegationProgress?
    /// A `resume_delegation`: the sub-agent came back.
    var resumed: Bool
    /// Why it was resumed, as the agent passed it on.
    var reason: String?

    /// No word from the broker yet, or running: the marker pulses.
    var working: Bool { status == .starting || status == .running }
    var settled: Bool { status == .ok || status == .err }
}

extension DelegationModel {
    /// Opening words of the broker's resume acknowledgement
    /// (`broker.rs::resume_ack`) — what is left of it on a host that drops
    /// `structuredContent`.
    static let resumedAckText = "Delegation resumed"

    /// A `resume_delegation` call. It re-runs a task under the ORIGINAL
    /// delegation's call id, so its own id is never a binding key.
    static func isResumeCall(_ vm: ToolCallVM) -> Bool {
        ToolNameNormalizer.normalizeToolName(vm.toolName).lowercased() == "resume_delegation"
    }

    /// Whether a call draws the delegation card: a delegate (by name, or an
    /// opencode code-mode script calling it), a resume, or a call the broker
    /// stamped — each on the call's own evidence, never a name inferred from
    /// a title that can quote anything.
    static func drawsCard(_ vm: ToolCallVM, kind: ToolStepKind) -> Bool {
        kind == .delegation || kind == .delegationResume || vm.companion == .delegate
            || parseDelegationMeta(vm.meta) != nil
    }

    /// Whether a `resume_delegation` result is the broker CONFIRMING the
    /// resume, as opposed to refusing it or reporting an unknown task (web
    /// `isAffirmedResume`). With the report intact, naming a child IS the
    /// confirmation; without it, only the acknowledgement's words are left.
    static func isAffirmedResume(output: String?, errorText: String?) -> Bool {
        if isRefusedResume(output: output, errorText: errorText) { return false }
        let parsed = (errorText?.isEmpty == false ? parseToolOutput(errorText, forceError: true) : nil)
            ?? parseToolOutput(output)
        if parsed?.report != nil { return parsed?.childConversationId != nil }
        return [parsed?.outcomeText, output, errorText].contains { candidate in
            guard let candidate else { return false }
            return ToolNameNormalizer.jsTrimStart(candidate).utf16.starts(with: resumedAckText.utf16)
        }
    }

    /// The broker's running ack as a host that kept only its text shows it
    /// (codex's history parser writes a code-mode delegation's result so):
    /// still an ack, not a finished task — and never its result.
    static let bareAckText = "Delegation successful."

    static func isBareAck(_ output: DelegationToolOutput?) -> Bool {
        guard case .outcome(let text, false, _, nil)? = output else { return false }
        return ToolNameNormalizer.jsTrimStart(text).hasPrefix(bareAckText)
    }

    /// The child a bare ack names (`child_conversation_id=901.`).
    private static func bareAckChild(_ text: String) -> Int? {
        Rx.capture(text, #"child_conversation_id=(\d+)"#, groups: 1).flatMap { Int($0[0]) }
    }

    /// The live binding this call stands for (web `useDelegationCardModel`'s
    /// binding resolution). A delegate's id IS its binding's key. A resume is
    /// found by the task id it names — an argument the model wrote, so only
    /// on this call's own evidence: the result names the same child
    /// conversation, or, where no report survived, affirms the resume. A
    /// refusal ("Unknown task id") affirms nothing.
    static func binding(for vm: ToolCallVM, in bindings: [DelegationBinding]) -> DelegationBinding? {
        if let direct = bindings.first(where: { $0.parentToolUseId == vm.id }) { return direct }
        guard isResumeCall(vm),
              let taskId = ActivityJSON.findStringFieldDeep(vm.input, key: "task_id"), !taskId.isEmpty,
              let match = bindings.first(where: { $0.info.taskId == taskId }) else { return nil }
        let pair = outputError(vm)
        let output = parseToolOutput(vm.output, forceError: vm.isError)
        if let named = output?.childConversationId ?? parseDelegationMeta(vm.meta)?.childConversationId {
            return named == match.info.childConversationId ? match : nil
        }
        return isAffirmedResume(output: pair.output, errorText: pair.errorText) ? match : nil
    }

    /// The newest check on `taskId` among the checks that came after the call
    /// (web `useLatestTaskRow`): what says how the task ended when nothing
    /// live or stored does.
    static func latestTaskRow(_ polls: [ToolCallVM]?, taskId: String?) -> DelegationTaskRow? {
        guard let polls, !polls.isEmpty else { return nil }
        let rows = buildTaskRows(polls)
        return rows.first { $0.taskId == taskId } ?? rows.last
    }

    /// How a task ended, as a check reported it — nil while it still runs
    /// (web `taskEnding`).
    static func ending(_ report: StatusReport?) -> ResolvedBadge? {
        guard let report, let status = report.status, status != .running else { return nil }
        let badge = deriveBadge(kind: .status, report: report, state: .done, hasError: false)
        return badge.status == .ok || badge.status == .err ? badge : nil
    }

    /// Everything a delegation's card and marker say, in priority order: the
    /// live `binding` → the broker's stamp on the call's meta → the call's own
    /// arguments and result → the newest check on its task (`later`). Nil when
    /// there is nothing to draw it by, or for a resume the broker refused
    /// (that card states the reason instead).
    static func card(_ vm: ToolCallVM, binding: DelegationBinding?, later: DelegationTaskRow?) -> DelegationCard? {
        let resumed = isResumeCall(vm)
        if resumed, vm.hasOutput, isRefusedResume(vm) { return nil }
        // A resume's `{task_id, reason}` carries none of what a delegate's
        // arguments say.
        let args = resumed ? DelegationParsedInput() : parseInput(vm.input)
        let stamped = parseDelegationMeta(vm.meta)
        let output = parseToolOutput(vm.output, forceError: vm.isError)
        let report = output?.report
        let hasModel = binding != nil || stamped != nil
            || args.agentType != nil || args.assistantId != nil || args.task != nil
            || report?.agentType != nil || output?.childConversationId != nil
        guard hasModel else { return nil }

        let checked = later?.report
        let ended = ending(checked)
        var status: DelegationCardStatus
        if let binding {
            switch binding.status {
            case .running: status = .running
            case .ok: status = .ok
            case .err: status = .err
            }
        } else if let stamped {
            status = stamped.status
        } else if vm.isError || vm.state == .error {
            status = .err
        } else if let ended {
            // A check that came back after the hand-over is newer than the
            // ack: with nothing live or stored, the card would run forever.
            status = ended.status == .ok ? .ok : .err
        } else if isBareAck(output) {
            status = .running
        } else {
            switch output {
            case .ack: status = .running
            case .outcome(_, let isError, _, _): status = isError ? .err : .ok
            case nil: status = vm.state == .done ? .ok : .starting
            }
        }
        // A check that found it parked on the user: it waits, it doesn't work.
        if status == .running, checked?.status == .running, checked?.blocked == true {
            status = .waiting
        }
        let settled = status == .ok || status == .err

        // What it came back with: the newest check's report once the task
        // ended, else a broker report the call returned itself (a fast
        // completion or a synchronous broker). Bare text is a host's rendering
        // of the ack, never the task's result.
        var outcome: String?
        if settled {
            if ended != nil {
                outcome = checked?.text
            } else if case .outcome(let text, _, _, .some) = output {
                outcome = text
            }
        }
        if outcome?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { outcome = nil }

        let reason = resumed
            ? ActivityJSON.findStringFieldDeep(vm.input, key: "reason")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let taskId = (resumed ? ActivityJSON.findStringFieldDeep(vm.input, key: "task_id") : nil)
            ?? parseDelegateTaskId(output: outputError(vm).output, errorText: outputError(vm).errorText)
            ?? binding?.info.taskId ?? stamped?.taskId ?? later?.taskId
        // The backend ignores a call's `agent_type` when it names an
        // assistant (the assistant decides), so a host that fills it in anyway
        // must not paint the wrong agent.
        let boundAgent: AgentType? = {
            guard let agent = binding?.info.agentType, !agent.rawValue.isEmpty else { return nil }
            return agent
        }()
        return DelegationCard(
            status: status,
            agentType: boundAgent
                ?? (args.assistantId == nil ? args.agentType : nil)
                ?? report?.agentType ?? stamped?.agentType ?? checked?.agentType,
            assistantName: binding?.info.assistantName ?? report?.assistantName ?? stamped?.assistantName,
            task: args.task ?? binding?.info.taskPreview ?? stamped?.task,
            taskId: taskId?.isEmpty == false ? taskId : nil,
            workingDir: args.workingDir?.isEmpty == false ? args.workingDir : nil,
            errorCode: binding?.errorCode ?? stamped?.errorCode ?? report?.errorCode ?? ended?.errorCode,
            childConversationId: binding.map(\.info.childConversationId).flatMap { $0 > 0 ? $0 : nil }
                ?? stamped?.childConversationId ?? output?.childConversationId
                ?? (isBareAck(output) ? output?.outcomeText.flatMap(bareAckChild) : nil)
                ?? checked?.childConversationId,
            durationMs: stamped?.durationMs ?? (settled ? checked?.durationMs : nil),
            outcome: outcome,
            progress: checked?.progress,
            resumed: resumed,
            reason: reason?.isEmpty == false ? reason : nil
        )
    }

    /// How a run of checks (or a cancel) stands, for its rail marker (web
    /// `pollsStatus`): waiting on the user first, then still running, then a
    /// failure, else done. A check that came back "still running" is a
    /// settled snapshot, not live work.
    static func checksStatus(_ polls: [ToolCallVM], kind: DelegationRowKind) -> DelegationCardStatus {
        let rows = buildTaskRows(polls, kind: kind)
        if rows.isEmpty {
            // Still in flight and naming no task: its card says running, so does its marker.
            return polls.contains { $0.state == .running || $0.state == .inputStreaming } ? .running : .ok
        }
        let badges = rows.map(\.badge.status)
        if badges.contains(.waiting) { return .waiting }
        if badges.contains(.running) || badges.contains(.starting) { return .running }
        if badges.contains(.err) { return .err }
        return .ok
    }

    /// A result's first line, as one line of plain words (web `previewLine`).
    static func previewLine(_ text: String?, limit: Int = 240) -> String? {
        guard let text else { return nil }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") }
        guard var plain = line else { return nil }
        while let first = plain.first, "#>-* ".contains(first) { plain.removeFirst() }
        plain = plain.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        plain = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        return plain.count > limit ? String(plain.prefix(limit)) : plain
    }
}

extension DelegationToolOutput {
    var childConversationId: Int? {
        switch self {
        case .ack(let id, _): return id
        case .outcome(_, _, let id, _): return id
        }
    }

    var outcomeText: String? {
        if case .outcome(let text, _, _, _) = self { return text }
        return nil
    }
}
