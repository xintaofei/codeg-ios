import SwiftUI

/// The Activity tab: a live monitor of what your agents are doing right now and
/// what just finished — running sessions on top, then everything touched in the
/// last 24 hours. Unlike the Chats list, rows are **directly tappable**: each
/// opens its session in a single tap, with no App Store-style card/zoom drill-in
/// in between (Activity favors immediacy — it's backed by a periodic poll that
/// keeps the list live). It's one plain `List` (UICollectionView cell recycling,
/// so a busy server's recent list scrolls smoothly) of session cards grouped
/// under tinted section headers. (Pending approvals join this screen once the permission flow lands.)
struct ActivityView: View {
    let activity: ActivityModel
    let client: CodegClient?
    /// The session that is open (iPad) or was opened last (iPhone); its row is
    /// marked.
    var markedConversationID: Int? = nil
    let onOpen: (Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Bumped only when a user pull-to-refresh completes, so the soft landing
    /// haptic fires on the pull — not on the initial programmatic load.
    @State private var pullTick = 0

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Activity", compact: horizontalSizeClass == .compact)
        // No explicit refresh button — pull-to-refresh and the background
        // activity pulse keep this current.
        .task {
            if !activity.hasLoaded {
                await activity.refresh(client: client)
            }
        }
    }

    // MARK: - Content states

    private var content: some View {
        Group {
            if client == nil {
                EmptyStateView(
                    icon: "server.rack",
                    title: "No Server Selected",
                    message: "Pick a server in the Chats tab to see its activity."
                )
            } else if !activity.hasLoaded, activity.isRefreshing {
                LoadingView(label: "Checking activity…")
            } else if let error = activity.error, !activity.hasLoaded {
                InlineErrorView(message: error) {
                    Task { await activity.refresh(client: client) }
                }
            } else {
                feed
            }
        }
        // Cross-fade the first load into the feed instead of a hard swap.
        .transition(.opacity)
        .animation(Theme.Motion.content, value: activity.hasLoaded)
    }

    // MARK: - Feed

    /// One plain `List` of directly-tappable rows under tinted "Running" /
    /// "Last 24 Hours" headers (read live each render, so a background pulse keeps
    /// them fresh). Rows, the refresh-error banner, the idle empty state, and the
    /// "Updated …" footer are all borderless list rows over the `ZStack`'s
    /// `CodegBackground`.
    private var feed: some View {
        let running = activity.running
        let recent = activity.recent

        return List {
            // A failed refresh over a list that still has rows: surface the error
            // inline above the sections rather than swallowing it.
            if let error = activity.error, activity.hasLoaded {
                RefreshErrorBanner(
                    message: error,
                    retry: { Task { await activity.refresh(client: client) } },
                    dismiss: { activity.dismissError() }
                )
                .plainRow(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if running.isEmpty, recent.isEmpty {
                EmptyStateView(
                    icon: "moon.zzz",
                    title: "All Agents Idle",
                    message: "Nothing is running and nothing finished in the last 24 hours."
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .plainRow(EdgeInsets())
            } else {
                if !running.isEmpty {
                    sectionHeader("Running", count: running.count,
                                  icon: "waveform", tint: Theme.accent)
                    ForEach(running) { row($0) }
                }
                if !recent.isEmpty {
                    sectionHeader("Last 24 Hours", count: recent.count,
                                  icon: "clock.arrow.circlepath", tint: Theme.textSecondary)
                    ForEach(recent) { row($0) }
                }
            }

            if let refreshed = activity.lastRefreshed {
                Text("Updated \(RelativeTime.string(from: refreshed))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .plainRow(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .refreshable {
            await activity.refresh(client: client)
            pullTick &+= 1
        }
        // Ease rows between Running ↔ Last-24h as the background poll reorders
        // them, instead of teleporting (this list refreshes live).
        .animation(Theme.Motion.chrome, value: running.map(\.id))
        .animation(Theme.Motion.chrome, value: recent.map(\.id))
        // A soft tick when a user pull-to-refresh lands (not the initial load).
        .sensoryFeedback(.impact(flexibility: .soft), trigger: pullTick)
    }

    /// One directly-tappable session card (opens in a single tap), as in
    /// ``SearchView``'s result list and ``SessionSectionFullScreen``.
    private func row(_ conversation: ConversationSummary) -> some View {
        SessionRow(
            conversation: conversation,
            isSelected: conversation.id == markedConversationID,
            folderName: activity.folderNames[conversation.folderId],
            onTap: { onOpen(conversation.id) }
        )
        .plainRow(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    /// A group header above its cards: a tinted circular badge + the section
    /// name + a count pill.
    private func sectionHeader(_ title: LocalizedStringKey, count: Int,
                               icon: String, tint: Color) -> some View {
        HStack(spacing: 11) {
            SectionBadgeIcon(systemImage: icon, tint: tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            CountBadge(count: count)
        }
        .plainRow(EdgeInsets(top: 16, leading: 18, bottom: 6, trailing: 18))
    }
}

private extension View {
    /// Shared list-row chrome for this screen: explicit insets, no separator, and
    /// a clear background so the `ZStack`'s `CodegBackground` shows through.
    func plainRow(_ insets: EdgeInsets) -> some View {
        self
            .listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
