import Foundation
import Observation

/// Fold state for a transcript's replies — port of the web's `ReplyFoldState`
/// (`message-list-view.tsx`) and `CompletedTurnContent`'s manual overrides
/// (codeg 0.44). Owned by the session's view model, not by the turns.
///
/// - The CURRENT round is the newest reply once the agent has started replying
///   in this visit (`armed`). It shows expanded and keeps the reader's toggle
///   POSITIONALLY: a reply's identity changes twice on its way into history
///   (the live turn settling, then the reconciled transcript renaming it), so
///   a toggle keyed by id would drop the expansion mid-read — the reply would
///   fold itself up the moment it finished.
/// - Every other reply starts folded once complete; a toggle by hand sticks,
///   keyed by the reply's id and stamped with the fold `epoch`.
/// - Every send bumps the epoch, so ONE number folds everything above the new
///   message: an override written under an earlier epoch stops matching.
///
/// A freshly opened session is not armed — its replies all open folded.
@MainActor
@Observable
final class ReplyFoldStore {
    private(set) var epoch = 0
    /// The agent has started replying since the last send.
    private(set) var armed = false
    private var roundOpen = true
    private var manual: [String: (epoch: Int, open: Bool)] = [:]

    /// The user sent: a new round begins, and every reply above it folds.
    func beginRound() {
        epoch &+= 1
        armed = true
        roundOpen = true
    }

    /// This screen attached to a reply already being written (opened mid-turn,
    /// or reconnected): it becomes the current round, without folding anything
    /// — and a reattach to the round already armed keeps the reader's toggle.
    func arm() {
        guard !armed else { return }
        armed = true
        roundOpen = true
    }

    func isOpen(_ key: String, isCurrent: Bool, completed: Bool) -> Bool {
        if isCurrent && armed { return roundOpen }
        if let entry = manual[key], entry.epoch == epoch { return entry.open }
        // A reply still being written is never folded by default.
        return !completed
    }

    /// When the reader last folded or unfolded a reply (system uptime, 0
    /// before any) — see ``DisclosureStore/lastChoiceAt``.
    @ObservationIgnored private(set) var lastChoiceAt: TimeInterval = 0

    func setOpen(_ open: Bool, key: String, isCurrent: Bool) {
        lastChoiceAt = ProcessInfo.processInfo.systemUptime
        if isCurrent && armed {
            roundOpen = open
        } else {
            manual[key] = (epoch, open)
        }
    }
}
