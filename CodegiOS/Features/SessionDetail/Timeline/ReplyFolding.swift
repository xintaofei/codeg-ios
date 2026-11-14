import Foundation

/// Applies the replies' fold state to a built node list — the cheap pass that
/// runs AFTER the memoized persisted tier and the fresh live tier are joined,
/// so folding or unfolding a reply never invalidates the expensive build.
@MainActor
enum ReplyFolding {
    static func apply(_ nodes: [TimelineNode], store: ReplyFoldStore) -> [TimelineNode] {
        // The current round is positional: the newest reply on screen.
        let currentKey = nodes.last { $0.reply?.role == .header }?.reply?.key
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
                out.append(node)
            }
        }
        return out
    }
}
