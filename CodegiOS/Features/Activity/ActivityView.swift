import SwiftUI

/// The Activity tab: a live monitor of what your agents are doing right now and
/// what just finished — running sessions on top, then everything touched in the
/// last 24 hours. Unlike the Chats list, rows are **directly tappable**: each
/// opens its session in a single tap, with no App Store-style card/zoom drill-in
/// in between (Activity favors immediacy — it's backed by a periodic poll that
/// keeps the list live). It's one plain `List` (UICollectionView cell recycling,
/// so a busy server's recent list scrolls smoothly) grouped under tinted section
/// headers. (Pending approvals join this screen once the permission flow lands.)
struct ActivityView: View {
    @Environment(\.locale) private var locale
    let activity: ActivityModel
    let client: CodegClient?
    let onOpen: (Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Bumped only when a user pull-to-refresh completes, so the soft landing
    /// haptic fires on the pull — not on the initial programmatic load.
    @State private var pullTick = 0
    /// The server's tag definitions, for the rows' chips.
    @State private var tagDefinitions = TagDefinitionsModel()

    /// Who the tag definitions are read from — a token edit re-reads them too.
    private var tagSource: String {
        client.map { "\($0.baseURL.absoluteString)|\($0.token)" } ?? ""
    }

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
        // The rows carry their tags as the Chats list draws them: the
        // definitions read here and after every tag edit, each row's own tags
        // patched as soon as a write is confirmed (not at the next pulse).
        // Asked again each time the tab comes back; read again only once aged.
        .task(id: tagSource) { await loadTagDefinitions(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagDefinitionsDidChange)) { _ in
            Task { await loadTagDefinitions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagsDidChange)) { note in
            if let change = note.object as? ConversationTagsChange { activity.applyTagChange(change) }
        }
    }

    private func loadTagDefinitions(force: Bool = true) async {
        if let client {
            if force {
                await tagDefinitions.load(client: client)
            } else {
                await tagDefinitions.loadIfStale(client: client)
            }
        } else {
            tagDefinitions.reset()
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
                Text("Updated \(RelativeTime.string(from: refreshed, locale: locale))")
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

    /// One directly-tappable session row (opens in a single tap). Mirrors
    /// ``SearchView``'s flat result list and ``SessionSectionFullScreen``'s row
    /// styling — borderless over the screen background.
    private func row(_ conversation: ConversationSummary) -> some View {
        SessionRow(
            conversation: conversation,
            isSelected: false,
            folderName: activity.folderNames[conversation.folderId],
            onTap: { onOpen(conversation.id) },
            rowTags: tagDefinitions.rowTags(for: conversation)
        )
        .plainRow(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }

    /// A group header: a tinted circular badge (same 26 pt diameter as the row
    /// avatars, so the title lines up under the row titles) + the section name +
    /// a count pill.
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
        .plainRow(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
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
