import Foundation

/// An async sub-agent launch's lifecycle (web `lib/background-agent.ts`). The
/// server's history parser rewrites the launch ack's output — internal text
/// never meant for the reader — into this marker plus one line of JSON, joined
/// with the latest `<task-notification>` for the task; a live settle rewrites
/// it the same way in memory (`settle`).
///
/// A `nil` status means no notification was seen: the card reads "launched ·
/// result pending", never "running" — the transcript alone cannot tell a task
/// still running from one whose CLI died.
struct BackgroundTaskLifecycle: Equatable, Sendable {
    static let marker = "[[codeg-background-task]]"

    let taskId: String
    /// The latest notification's `<status>` (`completed` on success).
    let status: String?
    let summary: String?
    /// The notification's `<result>` markdown.
    let result: String?
    /// The task will notify again: its result may be interim.
    let interim: Bool

    /// The lifecycle a launch's output carries after the marker, else nil.
    static func parse(_ output: String?) -> BackgroundTaskLifecycle? {
        guard let output else { return nil }
        let trimmed = output.drop { $0.isWhitespace }
        guard trimmed.hasPrefix(marker) else { return nil }
        let payload = trimmed.dropFirst(marker.count)
        guard let data = String(payload).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let taskId = object["task_id"] as? String else { return nil }
        func text(_ key: String) -> String? { object[key] as? String }
        let interim = (object["interim"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return BackgroundTaskLifecycle(taskId: taskId, status: text("status"), summary: text("summary"),
                                       result: text("result"), interim: interim)
    }

    /// The output the history parser would write for `settled`.
    static func markerText(for settled: BackgroundSettled) -> String {
        var object: [String: Any] = ["task_id": settled.taskId, "status": settled.status]
        if let summary = settled.summary { object["summary"] = summary }
        if let result = settled.result { object["result"] = result }
        if settled.interim { object["interim"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return marker + (String(data: data, encoding: .utf8) ?? "{}")
    }

    /// Whether `output` is one of the acks an agent answers a background
    /// launch with, before anything settles it.
    static func isLaunchAck(_ output: String?) -> Bool {
        guard let output else { return false }
        let text = output.drop { $0.isWhitespace }
        return output.contains("Async agent launched successfully")
            || text.hasPrefix("Subagent started in background")
            || text.hasPrefix("The subagent is working in the background (sessionID:")
    }

    /// `turns` with `settled`'s launch card flipped to its settle: the
    /// launch's result rewritten to the marker the history parser would write.
    /// Only a launch card — a background shell's notification names its
    /// command call too, and that card stays as it is. Nil when nothing
    /// matched, so a caller can leave its array (and its version) alone.
    static func settle(_ turns: [MessageTurn], _ settled: BackgroundSettled) -> [MessageTurn]? {
        guard let callID = settled.toolUseId, !callID.isEmpty else { return nil }
        let marker = markerText(for: settled)
        var changed = false
        let next = turns.map { turn -> MessageTurn in
            var turnChanged = false
            let blocks = turn.blocks.map { block -> ContentBlock in
                guard case .toolResult(let id, let preview, let isError, let stats, let exitCode) = block,
                      id == callID, preview != marker,
                      isLaunchAck(preview) || parse(preview) != nil else { return block }
                turnChanged = true
                return .toolResult(id: id, outputPreview: marker, isError: isError, agentStats: stats, exitCode: exitCode)
            }
            guard turnChanged else { return turn }
            changed = true
            return MessageTurn(id: turn.id, role: turn.role, blocks: blocks, timestamp: turn.timestamp,
                               usage: turn.usage, durationMs: turn.durationMs, model: turn.model,
                               completedAt: turn.completedAt)
        }
        return changed ? next : nil
    }
}

/// An out-of-turn turn shown ahead of the detail read that brings it, and how
/// far the agent's transcript had been read when it came.
struct BackgroundOverlayEntry: Hashable, Sendable {
    let turn: MessageTurn
    let watermark: Int64
}

/// The out-of-turn transcript overlay (web 0.44 `conversation-runtime-store.ts`
/// `APPLY_BACKGROUND_ACTIVITY` / `retireCoveredBackgroundTurns`; Android
/// `BackgroundOverlays`): facts the agent already wrote to its transcript —
/// background completions, its work after them, cron and loop turns, none of
/// which come over the wire — shown as they happen, then retired once a
/// detail read covers them, so the two copies never stand together.
enum BackgroundOverlays {
    /// Cron / loop turns never settle, so nothing else bounds it.
    static let hardCap = 200

    /// Upsert a batch's turns by id (they are re-sent whole while they grow).
    static func upsert(_ current: [BackgroundOverlayEntry], turns: [MessageTurn],
                       watermark: Int64) -> [BackgroundOverlayEntry] {
        guard !turns.isEmpty else { return current }
        var next = current
        for turn in turns {
            let entry = BackgroundOverlayEntry(turn: turn, watermark: watermark)
            if let at = next.firstIndex(where: { $0.turn.id == turn.id }) {
                next[at] = entry
            } else {
                next.append(entry)
            }
        }
        return next.count > hardCap ? Array(next.suffix(hardCap)) : next
    }

    /// Retire what a detail read covers: an entry read at or before its
    /// `watermark`. A windowed read only covers its window, so with
    /// `uncoveredMaxTs` (the newest timestamp above the window) an entry is
    /// retired only when it is provably inside the window — strictly newer.
    /// Nil when nothing retires.
    static func retire(_ current: [BackgroundOverlayEntry], watermark: Int64?,
                       uncoveredMaxTs: Date?) -> [BackgroundOverlayEntry]? {
        guard let watermark, !current.isEmpty else { return nil }
        let kept = current.filter { entry in
            if entry.watermark > watermark { return true }
            guard let uncoveredMaxTs else { return false }
            return entry.turn.timestamp <= uncoveredMaxTs
        }
        return kept.count == current.count ? nil : kept
    }

    /// The tool-call ids the overlay's turns name.
    static func callIDs(_ overlay: [BackgroundOverlayEntry]) -> Set<String> {
        var ids = Set<String>()
        for entry in overlay {
            for block in entry.turn.blocks {
                switch block {
                case .toolUse(let id, _, _, _, _): if let id { ids.insert(id) }
                case .toolResult(let id, _, _, _, _): if let id { ids.insert(id) }
                default: break
                }
            }
        }
        return ids
    }

    /// `turns` less those an overlay turn re-tells: a detail read can hold a
    /// background reply still growing, which the watcher then re-sends whole
    /// under its own id. The overlay copy is the newer (a read after it would
    /// have retired it), and drawn together every step would show twice.
    static func withoutRetold(_ turns: [MessageTurn], callIDs: Set<String>) -> [MessageTurn] {
        guard !callIDs.isEmpty else { return turns }
        return turns.filter { turn in
            !turn.blocks.contains { block in
                switch block {
                case .toolUse(let id, _, _, _, _): return id.map(callIDs.contains) ?? false
                case .toolResult(let id, _, _, _, _): return id.map(callIDs.contains) ?? false
                default: return false
                }
            }
        }
    }

    /// `local` and the overlay in wall-clock order: a foreground exchange
    /// between background turns keeps its place.
    static func interleave(_ local: [MessageTurn], _ overlay: [BackgroundOverlayEntry]) -> [MessageTurn] {
        guard !overlay.isEmpty else { return local }
        var out: [MessageTurn] = []
        out.reserveCapacity(local.count + overlay.count)
        var i = 0, j = 0
        while i < local.count || j < overlay.count {
            let takeLocal = j >= overlay.count || (i < local.count && local[i].timestamp <= overlay[j].turn.timestamp)
            if takeLocal { out.append(local[i]); i += 1 } else { out.append(overlay[j].turn); j += 1 }
        }
        return out
    }

    /// The turns the transcript draws: the server's (less what the overlay
    /// re-tells), then the overlay joined to the rounds this screen folded in
    /// itself (`localFrom`, an index into `turns`) in wall-clock order. The
    /// server's own turns all predate what is left of the overlay — a read
    /// after a turn retires it.
    static func compose(_ turns: [MessageTurn], localFrom: Int?, overlay: [BackgroundOverlayEntry]) -> [MessageTurn] {
        guard !overlay.isEmpty else { return turns }
        let split = min(max(0, localFrom ?? turns.count), turns.count)
        let retold = callIDs(overlay)
        let server = withoutRetold(Array(turns[..<split]), callIDs: retold)
        let local = withoutRetold(Array(turns[split...]), callIDs: retold)
        return server + interleave(local, overlay)
    }
}
