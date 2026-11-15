import SwiftUI

/// An App Store editorial-style card wrapping one session group (Pinned / a
/// folder / Running / Last 24 Hours). It shows the group header plus a capped
/// preview of its rows; the **whole card** is a single tap target that
/// zoom-expands to a fullscreen list (``SessionSectionFullScreen``) via the
/// host's `.fullScreenCover` + `.navigationTransition(.zoom)`.
///
/// Preview rows are display-only (`SessionRow` with no `onTap`) so the card owns
/// the tap — matching the App Store pattern where you tap the card to open the
/// collection, then tap a row inside it.
struct SessionSectionCard: View {
    let title: String
    var tint: Color = Theme.accent
    let conversations: [ConversationSummary]
    /// Per-row folder tag (return `nil` to omit) — shown on cross-folder groups
    /// like Pinned / Other / Activity, hidden inside a single folder's card.
    var folderName: (ConversationSummary) -> String? = { _ in nil }
    /// Per-row tag chips (the Chats list resolves them; elsewhere none).
    var rowTags: (ConversationSummary) -> RowTags = { _ in .none }
    /// How many rows to preview before the "Show all" affordance.
    var previewLimit: Int = 5
    /// Whole-card tap → host presents the fullscreen list.
    let onExpand: () -> Void

    private var hasMore: Bool { conversations.count > previewLimit }

    var body: some View {
        Button(action: onExpand) {
            GlassCard(cornerRadius: Theme.Radius.lg, padding: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    header
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    ForEach(conversations.prefix(previewLimit)) { conv in
                        // No `onTap` → renders as a non-interactive preview row.
                        SessionRow(
                            conversation: conv,
                            isSelected: false,
                            folderName: folderName(conv),
                            rowTags: rowTags(conv)
                        )
                        .padding(.horizontal, 6)
                    }

                    if hasMore {
                        showAllFooter
                            .padding(.horizontal, 14)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(conversations.count) sessions")
        .accessibilityHint("Opens the full list")
    }

    /// "N sessions total" eyebrow shown above the title — mirrors the fullscreen
    /// drill-in (``SessionSectionFullScreen``) so a card reads as a preview of the
    /// very screen it zoom-expands into.
    private var totalLabel: LocalizedStringKey {
        let n = conversations.count
        return n == 1 ? "1 session total" : "\(n) sessions total"
    }

    /// A bigger, left-aligned title with a small tinted count eyebrow above it and
    /// no leading icon — the editorial-card look, matching the fullscreen header.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(totalLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .tracking(0.8)
                    .textCase(.uppercase)
                Text(LocalizedStringKey(stringLiteral: title))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // A subtle expand affordance (the whole card is tappable).
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var showAllFooter: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Show all \(conversations.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

/// The fullscreen drill-in a ``SessionSectionCard`` zoom-expands into. It's a real
/// `NavigationStack` so the close affordance is a **native toolbar button** — a
/// custom button floating over a `.navigationTransition(.zoom)` cover does NOT
/// reliably receive taps (the cover's interactive-dismiss layer eats them), which
/// is why an earlier hand-rolled floating "X" did nothing. The nav bar background
/// is hidden so that native close button floats over a clean top (App Store
/// editorial style) above a big left-aligned title with a small "N sessions total"
/// eyebrow. The row list is a `List` (UICollectionView cell recycling) so a
/// many-hundred-row group scrolls without the lazy-stack stutter. Rows are tappable
/// **only here**. Given a `routeScreen` (the phone), a tap pushes the conversation
/// onto this cover's own stack: Back comes back to this list, and only the close
/// button leaves it. (Pushed behind the cover while it zoomed away, the detail slid
/// in over the Chats list showing through, and Back landed on the Chats root.)
/// Without one (the iPad, whose detail column shows the pick), a tap reports the id
/// via `onOpen` and the host closes the cover. The close button reports via `onClose`.
struct SessionSectionFullScreen: View {
    let title: String
    var tint: Color = Theme.accent
    /// Passed fresh by the host each render (never a frozen snapshot), so a
    /// background refresh while this is open keeps the list current.
    let conversations: [ConversationSummary]
    var folderName: (ConversationSummary) -> String? = { _ in nil }
    var rowTags: (ConversationSummary) -> RowTags = { _ in .none }
    let onOpen: (Int) -> Void
    /// Draws what a row opens on this cover's own stack; nil sends the row to
    /// `onOpen` instead.
    var routeScreen: RouteScreen?
    var onTogglePin: ((ConversationSummary) -> Void)?
    /// What the rows' "Tags…" / "Move to…" do; nil offers neither. Their
    /// sheets are presented from inside this cover (see ``SessionRowSheets``).
    var rowActions: SessionRowActions?
    /// A move's outcome, told over this cover too (it ran from here).
    var notice: String?
    var onDismissNotice: () -> Void = {}
    /// Dismisses the fullscreen. The host drives this by clearing the cover's
    /// item binding (`expandedSection = nil`) — the same path the row-open flow
    /// uses. `@Environment(\.dismiss)` is a no-op for a cover presented with
    /// `.navigationTransition(.zoom)`, so the close button reports up instead.
    let onClose: () -> Void

    /// The conversation whose tags are being edited, or whose move is open,
    /// from a row's menu.
    @State private var tagging: ConversationSummary?
    @State private var moving: ConversationSummary?
    /// What this cover has pushed over its list.
    @State private var path: [Route] = []

    /// "N sessions total" eyebrow shown above the big title.
    private var totalLabel: LocalizedStringKey {
        let n = conversations.count
        return n == 1 ? "1 session total" : "\(n) sessions total"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                ForEach(conversations) { conv in
                    SessionRow(
                        conversation: conv,
                        isSelected: false,
                        folderName: folderName(conv),
                        onTap: { open(conv.id) },
                        onTogglePin: onTogglePin.map { toggle in { toggle(conv) } },
                        rowTags: rowTags(conv),
                        onEditTags: rowActions == nil ? nil : { tagging = conv },
                        onMove: rowActions == nil ? nil : { moving = conv }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(CodegBackground().ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // Hidden bar background → the close button floats over a clean top
            // (App Store look) instead of sitting on a visible band above the title.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: Route.self) { route in
                routeScreen?(route, push)
            }
        }
        // What a pushed screen opens (a fork's original) stays on this stack
        // too, rather than landing on the Chats stack hidden under the cover.
        .transformEnvironment(\.openCodegConversation) { action in
            guard routeScreen != nil else { return }
            action = OpenConversationAction { push(.conversation($0)) }
        }
        // Pulling a pushed conversation down must not throw the cover — and
        // the conversation with it — away; Back is the way out of it.
        .interactiveDismissDisabled(!path.isEmpty)
        .transientNotice(notice, dismiss: onDismissNotice)
        .sessionRowSheets(rowActions, tagging: $tagging, moving: $moving)
    }

    private func open(_ id: Int) {
        if routeScreen != nil {
            push(.conversation(id))
        } else {
            onOpen(id)
        }
    }

    private func push(_ route: Route) {
        guard path.last != route else { return }
        path.append(route)
    }

    /// Big left-aligned group title with a small total-count eyebrow above it —
    /// no leading icon, no trailing number (the editorial-card look).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(totalLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .tracking(0.8)
                .textCase(.uppercase)
            Text(LocalizedStringKey(stringLiteral: title))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        // Keep a long title clear of the floating close button.
        .padding(.trailing, 44)
    }
}

/// Draws a `Route` on a stack a screen keeps of its own — the app's one
/// registry of destinations — given what to do when the drawn screen opens
/// another route.
typealias RouteScreen = (_ route: Route, _ open: @escaping (Route) -> Void) -> AnyView
