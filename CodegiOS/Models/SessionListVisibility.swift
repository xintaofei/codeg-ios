import Foundation

/// Whether completed conversations appear in the Chats / Search lists.
///
/// Matches desktop sidebar `workspace:sidebar-show-completed`: default OFF so
/// finished sessions stay out of the way; only an explicit on reveals them.
/// Pinned rows stay visible either way, same as desktop's Pinned section.
enum SessionListPrefs {
    private static let key = "codeg.sessions.showCompleted"

    /// `false` when unset — same as desktop `loadShowCompleted()`.
    static var showCompleted: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return false }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Pure visibility rules for a conversation row. No I/O so the list view
/// model, Search, and unit tests share one source of truth.
enum SessionListVisibility {
    /// Desktop hides only `status == completed`. Cancelled / review stay.
    /// A pinned conversation is never hidden by this filter.
    static func isVisible(_ conv: ConversationSummary, showCompleted: Bool) -> Bool {
        if conv.isPinned { return true }
        if showCompleted { return true }
        return conv.status != .completed
    }

    static func filter(
        _ convs: [ConversationSummary],
        showCompleted: Bool
    ) -> [ConversationSummary] {
        convs.filter { isVisible($0, showCompleted: showCompleted) }
    }
}
