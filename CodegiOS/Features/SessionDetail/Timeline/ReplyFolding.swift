import Foundation

/// Applies the replies' fold state to a built node list — the cheap pass that
/// runs AFTER the memoized persisted tier and the fresh live tier are joined,
/// so folding or unfolding a reply never invalidates the expensive build.
@MainActor
enum ReplyFolding {
    /// - Parameter live: what the connection knows — a delegation pinned
    ///   under a folded reply stays only while it still works, and whether it
    ///   does can be news the memoized build never saw (its live binding).
    static func apply(_ nodes: [TimelineNode], store: ReplyFoldStore, live: ActivityLive = .none) -> [TimelineNode] {
        // The current round is positional: the newest reply on screen —
        // headerless or not.
        let currentKey = nodes.last { $0.reply != nil }?.reply?.key
        var open: [String: Bool] = [:]
        var out: [TimelineNode] = []
        out.reserveCapacity(nodes.count)
        for var node in nodes {
            guard let reply = node.reply else {
                out.append(node)
                continue
            }
            node.currentRound = reply.key == currentKey
            switch reply.role {
            case .header:
                guard case .replyHeader(let header) = node.content else { break }
                let isOpen = !header.foldable
                    || store.isOpen(reply.key, isCurrent: reply.key == currentKey, completed: header.completed)
                open[reply.key] = isOpen
                node.foldOpen = isOpen
                out.append(node)
            case .body, .foot:
                if open[reply.key] ?? true { out.append(node) }
            case .pinned:
                // Kept in view under a folded reply only while what it stands
                // for runs (web `pinnedOnly`, decided as the row draws).
                if !(open[reply.key] ?? true), case .delegation(let vm, let later) = node.content,
                   live.delegationCard(vm, later: later)?.settled == true {
                    break
                }
                out.append(node)
            case .always:
                out.append(node)
            }
        }
        return out
    }
}
