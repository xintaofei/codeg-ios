import Foundation
import Observation

/// What the conversation's connection is doing BESIDE the turn — the AIR
/// async-task table, the background sub-agents still out, the codeg
/// delegations still running — and the prompt the agent predicts the user
/// sends next. The state behind the composer's "N running" chip and its
/// suggested placeholder (web `ConnectionState.asyncTasks` /
/// `backgroundTasks` / `delegatedChildren` / `promptSuggestion`, plus the
/// `DelegationProvider` bindings). Also two facts about the connection's
/// agent process that the screen docks banners for: Claude Code's Remote
/// Control while it is on, and whether the process still runs on settings a
/// later save changed (web `remoteControl` / `configStale`). They live here for
/// the same reasons the rest does: both streams feed them, every snapshot
/// restates them, and they belong to one connection — a fork ends Remote
/// Control, and a new connection is a new process on the current settings.
///
/// Fed by BOTH streams on the connection — the turn's (forwarded by the view
/// model) and the idle ``ConnectionWatcher``'s between turns — which never run
/// at once. Everything here is current state that every snapshot restates, so
/// handing over from one stream to the other loses nothing.
///
/// Views observe this model directly rather than the view model, so a
/// running-list update never re-renders the transcript. The event cursor is
/// deliberately unobserved: it moves with every streamed token.
@MainActor
@Observable
final class ConnectionRunsModel {
    /// The connection this state describes. Ids (task ids, the cursor) mean
    /// nothing on another one, so a snapshot of a different connection starts
    /// over, and events arriving before any snapshot are not applied.
    private(set) var connectionID: String?
    /// The agent session (`external_id`) the task rows belong to.
    private(set) var sessionID: String?
    /// The last event seq applied, or the last fresh snapshot's.
    @ObservationIgnored private(set) var lastSeq: UInt64?

    /// AIR async tasks, settled rows included (see ``AsyncTasks``).
    private(set) var asyncTasks: [AsyncTaskRecord] = []
    /// `background_activity.outstanding_tasks`, whole.
    private(set) var backgroundTasks: [BackgroundOutstandingTask] = []
    /// Child connection ids of the delegations still running.
    private(set) var delegatedChildren: [String] = []
    /// Who each delegation is, finished ones included, in arrival order.
    private(set) var delegationBindings: [DelegationBinding] = []
    /// The predicted next prompt, trimmed; nil when none.
    private(set) var promptSuggestion: String?
    /// Claude Code's Remote Control while it is on.
    private(set) var remoteControl: RemoteControlInfo?
    /// The agent is on its launch-time settings after a later save; nil when not.
    private(set) var configStale: ConfigStale?
    /// The connection is running a turn — this screen's, or another client's
    /// it isn't following. What the banners' actions wait out: restarting the
    /// agent would kill the turn, and Claude Code refuses `/remote-control`
    /// while it works.
    private(set) var isPrompting = false
    /// The goal-control actions the adapter offers; nil while not known
    /// (fail-closed — the goal card offers none then). Fixed for the
    /// connection's life, so once known it is kept.
    private(set) var goalActions: [String]?

    /// A re-read of `connection`'s snapshot decided its goal vocabulary.
    func adoptGoalActions(_ actions: [String], connection: String) {
        guard connectionID == connection, goalActions == nil else { return }
        goalActions = actions
    }

    /// Tasks with a stop on its way. Held here rather than by the rows: a row
    /// leaves with the sheet, and back in view before the adapter answered it
    /// must not offer the stop again.
    private(set) var stoppingTaskIDs: Set<String> = []
    /// Why the last stop did nothing, for the sheet to say.
    var stopNotice: String?

    /// Sends a stop: `(connectionId, taskId) -> stopped`. Wired by the view model.
    @ObservationIgnored var stopAction: (@MainActor (String, String) async throws -> Bool)?
    /// A turn the agent started on its own just settled. Its content never
    /// streamed to this client (codeg draws it from the agent's transcript),
    /// so the owner re-reads the transcript. Wired by the view model.
    @ObservationIgnored var onAutonomousTurnSettled: (@MainActor () -> Void)?
    /// A fresh snapshot of `connection` left its goal vocabulary undecided
    /// (`initialize` still in flight). Wired by the view model to read again.
    @ObservationIgnored var onGoalActionsUndecided: (@MainActor (String) -> Void)?

    /// The running list the chip counts and the sheet draws.
    var liveRuns: LiveRuns {
        LiveRuns.collect(
            asyncTasks: asyncTasks,
            backgroundTasks: backgroundTasks,
            delegatedChildren: delegatedChildren,
            delegationBindings: delegationBindings)
    }

    // MARK: - Snapshots

    /// Adopt a connection snapshot (the attach handshake of either stream, or
    /// a reconnect's). Mirrors the web's `HYDRATE_FROM_SNAPSHOT`:
    ///
    /// - FRESH (its `event_seq` is past everything applied): it is the
    ///   backend's merge of every delta up to a seq this client hasn't reached,
    ///   so task rows are replaced by id, and the current-state fields — the
    ///   outstanding set, the running children, the suggestion — are taken as
    ///   they are.
    /// - STALE: it predates deltas already applied here. Replacing would walk a
    ///   task this client watched finish back to `running`, with no live event
    ///   left to correct it, so it may only ADD what was never seen.
    ///
    /// Task rows are additionally gated on the snapshot describing the SESSION
    /// they belong to: a fork leaves rows whose terminal frames publish on a
    /// session this connection has left.
    func hydrate(_ snap: LiveSessionSnapshot, connection: String) {
        if connectionID != connection {
            reset()
            connectionID = connection
        }
        let seq = snap.eventSeq ?? 0
        let r = snap.runs
        let sameSession = snap.externalId == nil || sessionID == nil || snap.externalId == sessionID
        let stale = lastSeq.map { seq <= $0 } ?? false

        if sameSession {
            let before = asyncTasks
            let next = stale ? AsyncTasks.adoptUnknown(before, r.asyncTasks) : AsyncTasks.merge(before, r.asyncTasks)
            if next != before {
                asyncTasks = next
                noteAutonomousTurnSettles(before: before, after: next)
            }
        } else if !stale {
            // A FRESH snapshot of another session: the connection moved on (a
            // fork) while nothing here was listening, so its `session_started`
            // was never seen and will not replay. The rows held are the session
            // it left — their terminal frames publish there now, and nothing
            // would ever settle them — so this snapshot's table is the whole
            // truth. (The web never stops listening, so it never needs this.)
            // A STALE one stays ignored: every session this model took on came
            // with a seq, so a read from before it is stale by definition.
            let next = AsyncTasks.merge([], r.asyncTasks)
            if next != asyncTasks { asyncTasks = next }
        }
        // Bindings say who a child is, never whether it runs — a stale one may
        // still introduce a child, but only a fresh one restates one.
        for info in r.activeDelegations where !info.parentToolUseId.isEmpty {
            let known = delegationBindings.contains { $0.parentToolUseId == info.parentToolUseId }
            if stale, known { continue }
            upsertBinding(DelegationBinding(info: info, status: .running, errorCode: nil))
        }
        guard !stale else { return }
        // A fresh snapshot restates every delegation still running. One held
        // here as running that it leaves out ended while nothing listened —
        // its completion went to nobody — so its binding no longer says how it
        // stands, and must not outrank the call's own stamp, which does by now.
        let restated = Set(r.activeDelegations.map(\.parentToolUseId))
        if delegationBindings.contains(where: { $0.status == .running && !restated.contains($0.parentToolUseId) }) {
            delegationBindings.removeAll { $0.status == .running && !restated.contains($0.parentToolUseId) }
        }
        assignIfChanged(\.sessionID, snap.externalId)
        assignIfChanged(\.backgroundTasks, r.backgroundOutstandingTasks)
        assignIfChanged(\.delegatedChildren, r.delegatedChildren)
        // Current state like the rest: a stale snapshot never reaches here, so
        // it cannot bring back a prediction a later prompt already spent.
        assignIfChanged(\.promptSuggestion, PromptSuggestionGate.normalized(r.promptSuggestion))
        assignIfChanged(\.remoteControl, r.remoteControl)
        assignIfChanged(\.configStale, Self.restated(configStale, stale: r.configStale, kind: r.configStaleKind))
        assignIfChanged(\.isPrompting, snap.status == .prompting)
        if goalActions == nil { assignIfChanged(\.goalActions, r.goalActions) }
        // `initialize` hasn't answered yet: the owner reads it again.
        if goalActions == nil { onGoalActionsUndecided?(connection) }
        lastSeq = seq
    }

    // MARK: - Events

    /// Apply one event of the connection this model was hydrated for, at most
    /// once: an envelope at or below the cursor was already applied (a replay
    /// overlapping the live tail, or the other stream's copy). `seq == 0`
    /// means the frame carried none — never treated as a duplicate.
    func apply(_ event: AcpEvent, seq: UInt64) {
        guard connectionID != nil else { return }
        if seq > 0 {
            if let last = lastSeq, seq <= last { return }
            lastSeq = seq
        }
        switch event {
        case .asyncTask(let delta):
            let before = asyncTasks
            let next = AsyncTasks.upsert(before, delta)
            if next != before {
                asyncTasks = next
                noteAutonomousTurnSettles(before: before, after: next)
            }

        case .backgroundActivity(let tasks, _):
            assignIfChanged(\.backgroundTasks, tasks)

        case .delegationStarted(let info):
            upsertBinding(DelegationBinding(info: info, status: .running, errorCode: nil))

        case .delegationCompleted(let info, let succeeded, let errorCode):
            // A missed start (attached mid-flight) still gets a binding, with
            // the agent the completion carries; the task label is unknown then.
            var binding = delegationBindings.first { $0.parentToolUseId == info.parentToolUseId }
                ?? DelegationBinding(info: info, status: .running, errorCode: nil)
            binding.status = succeeded ? .ok : .err
            binding.errorCode = succeeded ? nil : errorCode
            upsertBinding(binding)

        case .delegationChildRunning(let child, let running):
            let isListed = delegatedChildren.contains(child)
            if running, !isListed {
                delegatedChildren.append(child)
            } else if !running, isListed {
                delegatedChildren.removeAll { $0 == child }
            }

        case .promptSuggestion(let text):
            assignIfChanged(\.promptSuggestion, PromptSuggestionGate.normalized(text))

        case .statusChanged(let status):
            assignIfChanged(\.isPrompting, status == .prompting)
            switch status {
            case .prompting:
                // The prediction was for this prompt's place, so it is spent
                // whatever was sent — and by whichever client.
                assignIfChanged(\.promptSuggestion, nil)
            case .disconnected, .error:
                // Remote Control ran in the agent CLI, which is gone.
                assignIfChanged(\.remoteControl, nil)
            case .connecting, .connected:
                break
            }

        case .remoteControl(let info):
            assignIfChanged(\.remoteControl, info)

        case .sessionConfigStale(let stale, let kind):
            // A fresh drift shows again even after a dismissed one; a reverted
            // one clears.
            assignIfChanged(\.configStale, stale ? ConfigStale(kind: kind) : nil)

        case .sessionStarted(let id):
            // A CHANGED session id (a fork) strands the task rows: their
            // terminal frames publish on the session left behind. Nothing else
            // would ever settle them. The prediction followed that session's
            // last turn, too. A replayed announcement changes nothing.
            if sessionID != id {
                assignIfChanged(\.asyncTasks, [])
                assignIfChanged(\.promptSuggestion, nil)
                // Remote Control belongs to the session left behind, whose CLI
                // codeg closes after the fork.
                assignIfChanged(\.remoteControl, nil)
                sessionID = id
            }

        default:
            break
        }
    }

    // MARK: - Local transitions

    /// The user sent a prompt from here: the prediction is spent.
    func clearPromptSuggestion() {
        assignIfChanged(\.promptSuggestion, nil)
    }

    /// Hide the "restart to apply" banner for the drift on screen. Client-local:
    /// the connection is still stale, and a later drift shows it again.
    func dismissConfigStale() {
        guard var stale = configStale, !stale.dismissed else { return }
        stale.dismissed = true
        configStale = stale
    }

    /// A snapshot's staleness, keeping the dismissal of the drift it restates.
    /// A different kind is a drift this client never saw announced (the event
    /// fired while nothing here listened), so it shows.
    static func restated(_ current: ConfigStale?, stale: Bool, kind: ConfigStaleKind?) -> ConfigStale? {
        guard stale else { return nil }
        if let current, current.kind == kind { return current }
        return ConfigStale(kind: kind)
    }

    /// The connection is gone: nothing it listed can still be running.
    /// Scoped to the connection the caller saw go, so a late report about an
    /// old one can't wipe the state of the current one.
    func connectionGone(_ connection: String) {
        guard connectionID == nil || connectionID == connection else { return }
        reset()
    }

    /// The screen let go of the connection (a draft switched agent or folder).
    func clear() {
        reset()
    }

    private func reset() {
        connectionID = nil
        sessionID = nil
        lastSeq = nil
        assignIfChanged(\.asyncTasks, [])
        assignIfChanged(\.backgroundTasks, [])
        assignIfChanged(\.delegatedChildren, [])
        assignIfChanged(\.delegationBindings, [])
        assignIfChanged(\.promptSuggestion, nil)
        assignIfChanged(\.remoteControl, nil)
        assignIfChanged(\.configStale, nil)
        assignIfChanged(\.isPrompting, false)
        assignIfChanged(\.goalActions, nil)
        assignIfChanged(\.stoppingTaskIDs, [])
        stopNotice = nil
    }

    // MARK: - Stop

    /// Ask the adapter to stop one task. The row leaves when the task's
    /// terminal state arrives — the real confirmation — so the spinner is only
    /// held for the round-trip: kept on a `false` verdict, the user would have
    /// no way to try again.
    func stop(_ taskID: String) {
        guard let conn = connectionID, let stopAction, !stoppingTaskIDs.contains(taskID) else { return }
        stoppingTaskIDs.insert(taskID)
        stopNotice = nil
        Task { [weak self] in
            let outcome: Result<Bool, Error>
            do { outcome = .success(try await stopAction(conn, taskID)) } catch { outcome = .failure(error) }
            guard let self else { return }
            self.stoppingTaskIDs.remove(taskID)
            // Answered for a connection this screen has since left.
            guard self.connectionID == conn else { return }
            switch outcome {
            case .success(true):
                break
            case .success(false):
                self.stopNotice = String(localized: "That task could not be stopped — it may have already finished.")
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.stopNotice = String(localized: "Failed to stop the task: \(reason)")
            }
        }
    }

    // MARK: - Helpers

    private func upsertBinding(_ binding: DelegationBinding) {
        if let index = delegationBindings.firstIndex(where: { $0.parentToolUseId == binding.parentToolUseId }) {
            if delegationBindings[index] != binding { delegationBindings[index] = binding }
        } else {
            delegationBindings.append(binding)
        }
    }

    /// A turn task that was live and is now settled — its content landed in
    /// the agent's transcript, which this client never saw stream.
    private func noteAutonomousTurnSettles(before: [AsyncTaskRecord], after: [AsyncTaskRecord]) {
        let settled = after.contains { row in
            row.taskType == AsyncTasks.autonomousTurnTaskType && AsyncTasks.isTerminal(row)
                && before.contains { $0.taskId == row.taskId && !AsyncTasks.isTerminal($0) }
        }
        if settled { onAutonomousTurnSettled?() }
    }

    /// `@Observable` notifies on every write, equal or not: only write what changed.
    private func assignIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<ConnectionRunsModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
