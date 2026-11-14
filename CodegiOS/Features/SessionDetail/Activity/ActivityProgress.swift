import Foundation

/// How a finished step ended (web `StepMark`).
enum StepMark: String, Equatable, Hashable, Sendable {
    case ok, failed
}

/// How far a sub-agent or delegated agent has got (web `StepProgress`).
struct StepProgress: Equatable, Hashable, Sendable {
    /// Steps finished so far.
    var steps: Int
    /// How the latest finished steps ended, oldest first; at most
    /// ``ActivityProgress/maxStepMarks`` (the rest are only counted).
    var marks: [StepMark]
    /// The latest step's title, finished or not.
    var lastStep: String?
}

/// One tool call as the tally sees it: how it ended (nil while it runs), and
/// its title (web `TalliedStep`).
struct TalliedStep: Equatable, Hashable, Sendable {
    var mark: StepMark?
    var title: String?
}

/// How far a sub-agent or delegated agent has got, as its tool calls show: how
/// many it has finished, how the latest of them ended, and what it did last —
/// port of the web's `src/lib/activity/progress.ts` (codeg 0.44). Drawn as the
/// step bar under its row — one segment per finished step, never a percentage,
/// since nobody knows the total while it runs.
///
/// Three sources, one shape: a delegation's status report (`progress`, filled
/// by the broker from the child's session), the live child connection's
/// message, and a sub-agent's own recorded tool calls.
enum ActivityProgress {
    /// Segments the bar draws (Rust `MAX_STEP_MARKS`).
    static let maxStepMarks = 12

    /// A block of a live connection's message, as far as the tally needs it
    /// (web's structural `LiveBlock`): its `type`, and for a `tool_call` its
    /// status and title.
    struct LiveBlock: Equatable, Hashable, Sendable {
        struct Info: Equatable, Hashable, Sendable {
            var status: String
            var title: String
        }
        var type: String
        var info: Info?
    }

    /// Tally tool calls in the order they started. Nil when there are none.
    static func tallySteps<S: Sequence>(_ calls: S) -> StepProgress? where S.Element == TalliedStep {
        var steps = 0
        var marks: [StepMark] = []
        var lastStep: String?
        var any = false
        for call in calls {
            any = true
            lastStep = call.title
            guard let mark = call.mark else { continue }
            steps += 1
            marks.append(mark)
            if marks.count > maxStepMarks { marks.removeFirst() }
        }
        return any ? StepProgress(steps: steps, marks: marks, lastStep: lastStep) : nil
    }

    /// First line of a title, trimmed; nil when empty.
    static func cleanTitle(_ title: String?) -> String? {
        guard let line = title?.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else { return nil }
        return line
    }

    /// A status report's `progress` (`{steps, marks, last_step}`), if well-formed.
    /// `raw` is a `JSONSerialization` value.
    static func progressFromReport(_ raw: Any?) -> StepProgress? {
        guard let obj = raw as? [String: Any],
              let steps = ActivityJSON.int(obj["steps"]), steps >= 0 else { return nil }
        let marks = (obj["marks"] as? [Any])
            .map { list in list.compactMap { ($0 as? String).flatMap(StepMark.init(rawValue:)) }.suffix(maxStepMarks) }
            .map(Array.init) ?? []
        return StepProgress(
            steps: max(steps, marks.count),
            marks: marks,
            lastStep: cleanTitle(obj["last_step"] as? String)
        )
    }

    /// Progress of a live child connection's turn, from its message's tool calls
    /// in the order they started.
    static func progressFromLiveContent<S: Sequence>(_ content: S) -> StepProgress? where S.Element == LiveBlock {
        tallySteps(content.lazy.compactMap { block -> TalliedStep? in
            guard block.type == "tool_call", let info = block.info else { return nil }
            let mark: StepMark? = info.status == "completed" ? .ok : info.status == "failed" ? .failed : nil
            return TalliedStep(mark: mark, title: cleanTitle(info.title))
        })
    }

    /// A string that changes exactly when the drawn progress does.
    static func progressKey(_ progress: StepProgress?) -> String {
        guard let progress else { return "" }
        return "\(progress.steps)|\(progress.marks.map(\.rawValue).joined(separator: ","))|\(progress.lastStep ?? "")"
    }
}
