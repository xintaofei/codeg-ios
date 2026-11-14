import Foundation

/// Fold a reply's steps into the rows the timeline draws — port of the web's
/// `src/lib/activity/group.ts` (codeg 0.44).
///
/// - Consecutive exploration calls (read / search / glob / list / fetch / web
///   search / memory) become one "Explored" row; consecutive commands one "Ran
///   N commands" row. A run needs two members — a lone call stays a plain row.
/// - Everything else ends a run: thoughts, prose, edits, MCP and other tools,
///   sub-agents, plans, questions. A thought is the agent's own voice between
///   its calls, so it always stands as a row of its own. A FAILED call does not
///   end a run; it stays inside, and the group shows the failure.
/// - A group's key is its first member's, so a run that grows keeps its key
///   (and with it the reader's open/closed choice).
enum ActivityGroup {
    static func items(_ steps: [ActivityStep]) -> [ActivityItem] {
        var items: [ActivityItem] = []
        var run: (kind: ActivityGroupKind, members: [ActivityToolStep])?

        func flush() {
            guard let current = run else { return }
            if current.members.count >= 2 {
                items.append(.group(
                    key: current.members[0].key, kind: current.kind, steps: current.members,
                    status: ActivityStatus.combine(current.members.map(\.tool.status))))
            } else {
                for member in current.members { items.append(.step(.tool(member))) }
            }
            run = nil
        }

        for step in steps {
            if let tool = step.toolStep, let family = tool.tool.kind.family {
                if run?.kind == family {
                    run?.members.append(tool)
                    continue
                }
                flush()
                run = (family, [tool])
                continue
            }
            flush()
            items.append(.step(step))
        }
        flush()
        return items
    }

    /// The disclosure keys to open so the step `key` is in view: the step's
    /// own, and its group's when it is folded into one.
    static func disclosureKeys(for key: String, in items: [ActivityItem]) -> [String] {
        for item in items {
            if case .group(let groupKey, _, let steps, _) = item, steps.contains(where: { $0.key == key }) {
                return ["group:\(groupKey)", key]
            }
        }
        return [key]
    }
}
