import Foundation

/// What the live connection knows about a timeline that its transcript does
/// not carry (web `ActivityLiveValue`): which tool call a pending permission
/// request is about, and how the connection's permission requests were
/// answered. Laid over each row as it draws (web `useLiveToolStep`), after the
/// memoized build — a request coming or going never rebuilds a reply.
///
/// Only the session screen has one; a timeline drawn anywhere else (the
/// sub-agent viewer) simply has `none`.
struct ActivityLive: Equatable {
    /// The tool call a pending permission request is about.
    var awaitingToolCallId: String?
    /// The connection's answered permission requests, by tool call id.
    var approvals: ToolApprovalMap
    /// The connection's delegations as `delegation_started` / `_completed`
    /// and its snapshots bound them — who took each task and how it stands,
    /// fresher than anything stamped on the call.
    var delegations: [DelegationBinding] = []
    /// The thread's newest check on each delegated task, wherever in the
    /// thread it was made (the transcript sets it over its rows).
    var delegationTasks: DelegationTaskIndex = .empty
    /// How far each running delegated agent has got, from its own
    /// connection, by child connection id (web `useChildProgress`).
    var childProgress: [String: DelegationProgress] = [:]

    static let none = ActivityLive(awaitingToolCallId: nil, approvals: ActivityApproval.emptyToolApprovals)

    /// A delegation call's card, read against the live binding and the
    /// thread's newest check on its task — which a reply later than this one
    /// may hold (see ``DelegationModel/card(_:binding:later:)``). `later` is
    /// the newest check in the call's own reply.
    func delegationCard(_ vm: ToolCallVM, later: DelegationTaskRow?) -> DelegationCard? {
        DelegationModel.card(vm, binding: DelegationModel.binding(for: vm, in: delegations),
                             later: delegationTasks.row(for: vm.id) ?? later)
    }

    /// The live binding a delegation call stands for, if the connection has one.
    func delegationBinding(for vm: ToolCallVM) -> DelegationBinding? {
        DelegationModel.binding(for: vm, in: delegations)
    }

    /// A reply's summary with each delegation counted as its card stands
    /// (web reads the build's; a child that finished after the reply settled
    /// would leave the header saying nothing of it).
    func summary(of header: TimelineNode.ReplyHeader) -> ActivitySummary {
        guard header.hasDelegations else { return header.summary }
        return ActivitySummarize.summarize(header.steps) { step in
            delegationCard(step.call, later: DelegationModel.latestTaskRow(
                step.laterPolls, taskId: ActivitySummarize.delegationTaskId(step)))?.status
        }
    }

    /// Whether `step` is the call a pending permission request is about. A
    /// call that has already settled is not waiting on anyone, whatever the
    /// card says.
    func isAwaited(_ step: ActivityToolStep) -> Bool {
        guard let id = awaitingToolCallId, id == step.call.id else { return false }
        return step.tool.status != .succeeded && step.tool.status != .failed
    }

    /// `step`'s descriptor with what the connection knows:
    /// - the call a pending request is about waits on the user, whatever its
    ///   transcript state says;
    /// - a call whose request was answered carries the answer — the
    ///   connection's own record when it has one (the freshest), else the
    ///   stamp a detail load put on the call — and one the user declined that
    ///   the transcript only shows failing reads declined.
    func tool(for step: ActivityToolStep) -> ToolDescriptor {
        var tool = step.tool
        let approval = approvals[step.call.id].flatMap(ActivityApproval.approvalFromInfo) ?? tool.approval
        if isAwaited(step) {
            tool.status = .awaiting
        } else if approval?.decision == .rejected, tool.status == .failed {
            tool.status = .rejected
        }
        tool.approval = approval
        return tool
    }

    /// The member of a group a pending permission request is about, if any.
    func awaitedStep(in steps: [ActivityToolStep]) -> ActivityToolStep? {
        guard awaitingToolCallId != nil else { return nil }
        return steps.first { isAwaited($0) }
    }

    /// Whether a row draws its approval chip: a declined call whose row
    /// already says "declined" would only say it twice.
    static func showsApproval(_ approval: ToolApproval?, status: StepStatus) -> Bool {
        guard let approval else { return false }
        return !(approval.decision == .rejected && status == .rejected)
    }
}
