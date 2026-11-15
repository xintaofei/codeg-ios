import Foundation
import Observation
import SwiftUI

/// How far a delegated agent has got, from its own connection's message: its
/// tool calls in the order they started (web `progressFromLiveContent`). A
/// step is finished once its call completed or failed; the latest call's
/// title, finished or not, is what it is doing.
struct ChildStepTally: Equatable {
    private struct Call: Equatable {
        var status: String
        var title: String
    }

    private var order: [String] = []
    private var calls: [String: Call] = [:]

    init() {}

    /// The child's turn as its snapshot holds it.
    init(snapshot: LiveSessionSnapshot) {
        let active = Dictionary((snapshot.activeToolCalls ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for block in snapshot.liveMessage?.content ?? [] {
            guard case .toolCallRef(let id) = block, let call = active[id], calls[id] == nil else { continue }
            order.append(id)
            calls[id] = Call(status: call.status, title: call.label)
        }
    }

    /// Fold one of the child's events in. Returns whether the tally moved.
    @discardableResult
    mutating func apply(_ event: AcpEvent) -> Bool {
        let before = self
        switch event {
        case .toolCall(let id, let title, _, let status, _, _, _, _):
            if calls[id] == nil { order.append(id) }
            calls[id] = Call(status: status, title: title)
        case .toolCallUpdate(let id, let title, let status, _, _, _, _, _):
            guard var call = calls[id] else { return false }
            if let title, !title.isEmpty { call.title = title }
            if let status, !status.isEmpty { call.status = status }
            calls[id] = call
        case .userMessage:
            // A new prompt on the child (a resume): a new turn, counted afresh.
            self = ChildStepTally()
        default:
            return false
        }
        return self != before
    }

    /// `nil` while the child's turn has called no tool (web: no bar).
    var progress: DelegationProgress? {
        guard let last = order.last else { return nil }
        let steps = order.filter { id in
            let status = calls[id]?.status.lowercased()
            return status == "completed" || status == "failed"
        }.count
        let title = calls[last]?.title.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return DelegationProgress(steps: steps, lastStep: title?.isEmpty == false ? title : nil)
    }
}

/// Follows the connections of the delegations still running on this screen's
/// connection, for their live progress (web `useChildProgress`, fed by the
/// delegation context attaching each child). One socket per child, a few at
/// most; a child is let go a moment after its binding stops running (web
/// `CHILD_DETACH_GRACE_MS`) and its last tally with it — by then the card
/// reads how it ended from the binding and the checks.
@MainActor
@Observable
final class DelegationChildWatch {
    /// Each followed child's progress, by child connection id.
    private(set) var progress: [String: DelegationProgress] = [:]

    private final class Watch {
        let stream: EventStream
        let subscriptionID = UUID().uuidString
        var task: Task<Void, Never>?
        var tally = ChildStepTally()
        init(stream: EventStream) { self.stream = stream }
    }

    @ObservationIgnored private var watches: [String: Watch] = [:]
    @ObservationIgnored private var releases: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reopens: [String: Int] = [:]
    @ObservationIgnored private var reopenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var wanted: Set<String> = []
    @ObservationIgnored private var endpoint: (baseURL: URL, token: String)?

    static let maxChildren = 4
    private static let releaseGrace: Duration = .seconds(2)
    private static let maxReopens = 3

    /// Follow the children of the bindings still running; let go of the rest.
    func sync(_ bindings: [DelegationBinding], baseURL: URL, token: String) {
        endpoint = (baseURL, token)
        var next: [String] = []
        for binding in bindings where binding.status == .running && !binding.childConnectionId.isEmpty {
            if !next.contains(binding.childConnectionId) { next.append(binding.childConnectionId) }
        }
        wanted = Set(next.prefix(Self.maxChildren))
        for id in watches.keys where !wanted.contains(id) { release(id) }
        for id in wanted {
            releases.removeValue(forKey: id)?.cancel()
            if watches[id] == nil { open(id) }
        }
    }

    /// The screen is going: every socket closes, every tally goes.
    func stopAll() {
        wanted = []
        for id in Array(watches.keys) { close(id) }
        for task in releases.values { task.cancel() }
        releases = [:]
        for task in reopenTasks.values { task.cancel() }
        reopenTasks = [:]
        reopens = [:]
        if !progress.isEmpty { progress = [:] }
    }

    private func release(_ id: String) {
        guard releases[id] == nil else { return }
        releases[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseGrace)
            guard let self, !Task.isCancelled, !self.wanted.contains(id) else { return }
            self.releases[id] = nil
            self.close(id)
            self.reopens[id] = nil
            self.reopenTasks.removeValue(forKey: id)?.cancel()
            self.progress[id] = nil
        }
    }

    private func open(_ id: String) {
        guard let endpoint else { return }
        let stream = EventStream(baseURL: endpoint.baseURL, token: endpoint.token)
        let watch = Watch(stream: stream)
        watches[id] = watch
        stream.start()
        watch.task = Task { [weak self, weak watch] in
            for await frame in stream.frames {
                guard let self, let watch, !Task.isCancelled, self.watches[id] === watch else { return }
                switch frame {
                case .ready:
                    stream.attach(subscriptionId: watch.subscriptionID, connectionId: id)
                case .snapshot(let snap):
                    self.reopens[id] = 0
                    watch.tally = ChildStepTally(snapshot: snap)
                    self.publish(id, watch.tally)
                case .replay(let events):
                    for envelope in events { watch.tally.apply(envelope.event) }
                    self.publish(id, watch.tally)
                case .event(let envelope):
                    if watch.tally.apply(envelope.event) { self.publish(id, watch.tally) }
                case .pong:
                    break
                case .detached(let reason):
                    self.dropped(id, gone: reason == "connection_gone")
                    return
                case .closed:
                    self.dropped(id, gone: false)
                    return
                }
            }
        }
    }

    private func publish(_ id: String, _ tally: ChildStepTally) {
        let value = tally.progress
        if progress[id] != value { progress[id] = value }
    }

    /// The socket went. A child that is gone is let go; a blip is retried a
    /// few times while the binding still runs, keeping the tally meanwhile.
    private func dropped(_ id: String, gone: Bool) {
        close(id)
        guard !gone, wanted.contains(id) else { return }
        let attempt = (reopens[id] ?? 0) + 1
        reopens[id] = attempt
        guard attempt <= Self.maxReopens else { return }
        reopenTasks[id]?.cancel()
        reopenTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt)))
            guard let self, !Task.isCancelled, self.wanted.contains(id), self.watches[id] == nil else { return }
            self.reopenTasks[id] = nil
            self.open(id)
        }
    }

    private func close(_ id: String) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.task?.cancel()
        watch.stream.detach(subscriptionId: watch.subscriptionID)
        watch.stream.close()
    }
}

/// When each running delegation was first seen running on this screen (web
/// `useLiveElapsed`: "as far as this window has watched it"), by its call id.
/// Kept off the row so a card that scrolls out and back keeps counting from
/// where it started. Written while drawing, so it is not observed.
@MainActor
final class LiveClockStore {
    private var startedAt: [String: Date] = [:]
    private static let maxTracked = 512

    /// The moment `key` started running, recording now if it is new.
    func start(for key: String, now: Date = Date()) -> Date {
        if let known = startedAt[key] { return known }
        if startedAt.count >= Self.maxTracked { startedAt.removeAll(keepingCapacity: true) }
        startedAt[key] = now
        return now
    }

    /// `0:21`, `12:04`, `1:02:09` — a running clock, not a duration label.
    static func clock(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let ss = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        if hours > 0 { return "\(hours):\(minutes < 10 ? "0\(minutes)" : "\(minutes)"):\(ss)" }
        return "\(minutes):\(ss)"
    }

    /// A running step shows its clock once it has run this long.
    static let showsAfter: TimeInterval = 10
}

private struct LiveClockStoreKey: EnvironmentKey {
    static let defaultValue: LiveClockStore? = nil
}

extension EnvironmentValues {
    /// The session screen's running clocks; absent elsewhere (no clock drawn).
    var liveClocks: LiveClockStore? {
        get { self[LiveClockStoreKey.self] }
        set { self[LiveClockStoreKey.self] = newValue }
    }
}
