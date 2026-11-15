import Foundation

/// What the thread's checks say about each delegated task (Android
/// `DelegationTaskIndex`, web `linkLaterDelegationPolls` widened to the whole
/// thread): the agent hands a task over, goes on, and asks after it later —
/// often in another reply — yet the newest of those checks is how the
/// delegation stands. Each delegate call gets the newest check on its task; a
/// resume of the task takes over the checks that follow it.
///
/// Built from the persisted transcript once per persisted build (so it is as
/// stable as that memo): a check in the live reply is still that reply's own
/// (`laterPolls`), and the delegation it is about is drawn from the live
/// binding while the connection runs it anyway.
struct DelegationTaskIndex: Equatable {
    /// The newest check on each delegate (or resume) call's task, by the call's id.
    private(set) var byCall: [String: DelegationTaskRow] = [:]
    /// Which build this is. Equality is by it alone: the index only changes
    /// when the persisted tier is rebuilt, and the environment compares it
    /// on every pass.
    private(set) var version = 0

    static let empty = DelegationTaskIndex()

    init() {}

    init(byCall: [String: DelegationTaskRow], version: Int) {
        self.byCall = byCall
        self.version = version
    }

    func row(for callID: String) -> DelegationTaskRow? { byCall[callID] }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.byCall.count == rhs.byCall.count
    }
}

/// Folds a thread's steps, in order, into a ``DelegationTaskIndex``.
struct DelegationTaskFold {
    /// The call that owns each task's checks: the delegate call, then each
    /// resume of it in turn.
    private var ownerByTask: [String: String] = [:]
    private var taskByCall: [String: String] = [:]
    private var checksByCall: [String: [ToolCallVM]] = [:]
    private var order: [String] = []

    /// One reply's steps, in thread order (a goal run's are opened up).
    mutating func add(_ steps: [ActivityStep]) {
        for step in ActivitySummarize.flatten(steps) {
            switch step {
            case .tool(let tool) where tool.tool.kind == .delegation || tool.tool.kind == .delegationResume:
                // A refused resume revived nothing: the checks after it are
                // still the run's before it (`delegationTaskId` is nil then).
                guard let taskId = ActivitySummarize.delegationTaskId(tool) else { continue }
                ownerByTask[taskId] = tool.call.id
                taskByCall[tool.call.id] = taskId
            case .delegationPolls(_, let polls, _):
                for poll in polls {
                    let tasks = DelegationModel.buildTaskRows([poll]).compactMap(\.taskId)
                    var owners: [String] = []
                    for task in tasks {
                        if let owner = ownerByTask[task], !owners.contains(owner) { owners.append(owner) }
                    }
                    for owner in owners {
                        if checksByCall[owner] == nil { order.append(owner) }
                        checksByCall[owner, default: []].append(poll)
                    }
                }
            default:
                continue
            }
        }
    }

    func index(version: Int) -> DelegationTaskIndex {
        var byCall: [String: DelegationTaskRow] = [:]
        for call in order {
            guard let checks = checksByCall[call] else { continue }
            let rows = DelegationModel.buildTaskRows(checks)
            if let row = rows.first(where: { $0.taskId == taskByCall[call] }) ?? rows.last {
                byCall[call] = row
            }
        }
        return DelegationTaskIndex(byCall: byCall, version: version)
    }
}
