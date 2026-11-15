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

    static let none = ActivityLive(awaitingToolCallId: nil, approvals: ActivityApproval.emptyToolApprovals)

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
