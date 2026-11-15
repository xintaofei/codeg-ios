import Foundation
import Observation

/// What the reader opened or closed in one screen's transcript — a thought,
/// a tool row, a group, a background task, a compaction's summary, a clamped
/// panel's Show more. Owned by the session's view model, as the reply folds
/// are (``ReplyFoldStore``), and handed to the rows through the environment.
///
/// The transcript is a lazily recycled `List`: a row scrolled out of view and
/// back is a new view, and its `@State` starts over — so a thought the reader
/// expanded closed again. The choice lives here instead, under a key naming
/// the row (its timeline node id, which survives the live → history hand-off
/// wherever the row itself does) and the disclosure within it.
///
/// Only the reader's own choices are kept. A row that opens by itself — a
/// failure, a call waiting on the user, a command still running — reads its
/// default for as long as nothing is stored, and keeps following it until the
/// reader toggles it.
///
/// Per screen, never process-wide: codeg turn ids are not globally unique,
/// so a shared cache would hand one conversation's choices to another's rows.
/// Read only by the rows as they draw — never by the timeline build, so it is
/// no part of the persisted memo's key, and a toggle rebuilds nothing.
///
/// Observed key by key: a toggle wakes the row that reads that key, not every
/// row on screen. A key nobody has chosen for yet has no entry to observe, so
/// its readers watch `added` instead, and are woken once whenever a key is
/// chosen for the first time.
///
/// Main-thread only, like the views that read it. Not actor-annotated, so the
/// nonisolated ``DisclosureChoice`` property wrapper can read it as it draws.
@Observable
final class DisclosureStore {
    @ObservationIgnored private var entries: [String: DisclosureEntry] = [:]
    /// Bumped when a key is chosen for the first time.
    private var added = 0

    /// The reader's choice for `key`, or nil while they have made none.
    func choice(_ key: String) -> Bool? {
        if let entry = entries[key] { return entry.open }
        _ = added
        return nil
    }

    /// What `key` shows: the reader's choice, else the row's own default.
    func isOpen(_ key: String, default fallback: Bool) -> Bool {
        choice(key) ?? fallback
    }

    /// When the reader last made a choice (system uptime, 0 before any): the
    /// growth that follows is the row they tapped opening in place, which the
    /// transcript's follow-the-bottom leaves where it is.
    @ObservationIgnored private(set) var lastChoiceAt: TimeInterval = 0

    /// Record the reader's choice; nil hands the row back its default.
    func set(_ open: Bool?, for key: String) {
        lastChoiceAt = ProcessInfo.processInfo.systemUptime
        if let entry = entries[key] {
            if entry.open != open { entry.open = open }
            return
        }
        guard let open else { return }
        entries[key] = DisclosureEntry(open)
        added &+= 1
    }

    /// Flip what `key` shows.
    func toggle(_ key: String, default fallback: Bool) {
        set(!isOpen(key, default: fallback), for: key)
    }

    // MARK: Keys

    /// The key a disclosure called `name` remembers its state under, inside
    /// `scope` — the row it is drawn in, and the levels within it. Nil where
    /// there is no scope: such a disclosure keeps its own state.
    static func key(scope: String?, name: String) -> String? {
        scope.map { "\($0)/\(name)" }
    }
}

/// One key's choice, observed on its own.
@Observable
final class DisclosureEntry {
    var open: Bool?

    init(_ open: Bool?) {
        self.open = open
    }
}
