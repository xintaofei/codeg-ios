import SwiftUI

/// App shell. Adapts to width:
/// - **Compact** (iPhone): an iOS 26 Liquid Glass `TabView` — Chats · Folders
///   · Activity · Search · Settings, all in one glass capsule (Search is a plain
///   tab, not a detached search pill). Running tasks surface as a badge on the
///   Activity tab. The current server is switched from the Chats title menu;
///   opening a session pushes the detail (hiding the tab bar).
/// - **Regular** (iPad, landscape): a three-column `NavigationSplitView` whose
///   sidebar is the source list (Chats / Folders / Activity), with the same
///   server title menu and a gear that presents Settings as a sheet.
///
/// First launch with no saved servers shows the onboarding screen instead.
struct RootView: View {
    @State private var model = AppModel()
    @State private var appearance = AppearanceStore()
    @State private var language = LanguageStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.serverStore.servers.isEmpty {
                OnboardingView(store: model.serverStore) { profile in
                    model.selectedServerID = profile.id
                }
            } else if horizontalSizeClass == .compact {
                compactShell
            } else {
                splitShell
            }
        }
        .tint(Theme.accent)
        // Theme: the accent palette flows through a bridged UIKit trait so every
        // `Theme.accent` recolors live; mode drives light/dark/system. The store
        // is also placed in the environment so the Settings screen can edit it.
        // Applied on the outermost Group so sheets and the activity `.task`
        // inherit it. No `.id(...)` — accent/mode changes must not tear down
        // live SessionDetail streams.
        .environment(\.codegAccent, appearance.accent)
        .environment(appearance)
        // App display language: overriding `\.locale` re-resolves every
        // `LocalizedStringKey` live (no `.id(...)` teardown, so live streams
        // survive). `.system` hands back the device locale (a no-op override).
        .environment(language)
        .environment(\.locale, language.locale)
        .preferredColorScheme(appearance.mode.colorScheme)
        .onOpenURL { model.handle(url: $0) }
        .onChange(of: horizontalSizeClass, initial: true) { _, size in
            model.isCompact = size == .compact
        }
        // If the selected server is edited in place (same UUID, new endpoint),
        // its conversation/folder IDs may no longer be valid — drop them.
        // (Switching servers is handled by AppModel.selectedServerID.didSet.)
        .onChange(of: model.selectedServer?.urlString) { _, _ in
            model.selectedServerEndpointChanged()
        }
        // App-wide activity pulse: feeds the Activity tab, its sidebar badge,
        // and the bottom running bar. Restarts when the scene activates or the
        // server identity/endpoint changes; pauses in the background.
        .task(id: activityPulseID) {
            guard scenePhase == .active else { return }
            await model.activity.autoRefresh(client: model.selectedClient())
        }
        .sheet(isPresented: $model.serversSheetPresented) {
            ManageServersSheet(store: model.serverStore, selectedServerID: $model.selectedServerID)
        }
    }

    /// Identity for the activity poller's `.task` — composes everything that
    /// should restart the loop.
    private var activityPulseID: String {
        let server = model.selectedServerID?.uuidString ?? "none"
        let endpoint = model.selectedServer?.urlString ?? ""
        return "\(String(describing: scenePhase))|\(server)|\(endpoint)"
    }

    // MARK: - Compact width: bottom tab shell

    private var compactShell: some View {
        // A plain, always-solid tab bar: no scroll-driven minimize and no bottom
        // accessory, so nothing ever reserves an empty platter above the tabs.
        // Running tasks surface as the Activity tab's badge instead.
        //
        // Search is a *plain* tab (no `role: .search`) so it lives inside the same
        // glass capsule as the others rather than detaching into its own floating
        // pill — five evenly-spaced tabs make the capsule span close to the
        // conversation-list width. Settings stays last (conventional).
        TabView(selection: $model.selectedTab) {
            // Linear (outline) glyphs throughout — see `linearTabLabel`. iOS 26's
            // tab bar auto-fills any symbol with a `.fill` variant, which made
            // `message`/`folder`/`gearshape` read as solid color blocks; the
            // helper forces every icon to stay a stroke-only outline.
            Tab(value: AppTab.chats) {
                chatsTab
            } label: {
                linearTabLabel("Chats", "message")
            }
            Tab(value: AppTab.projects) {
                projectsTab
            } label: {
                linearTabLabel("Folders", "folder")
            }
            Tab(value: AppTab.activity) {
                activityTab
            } label: {
                linearTabLabel("Activity", "waveform")
            }
            // Running-task count rides the Activity tab as a badge (0 auto-hides).
            .badge(model.activity.running.count)
            Tab(value: AppTab.search) {
                searchTab
            } label: {
                linearTabLabel("Search", "magnifyingglass")
            }
            Tab(value: AppTab.settings) {
                settingsTab
            } label: {
                linearTabLabel("Settings", "gearshape")
            }
        }
    }

    /// A tab label that keeps its SF Symbol in the **outline** variant. iOS 26's
    /// tab bar otherwise auto-fills any symbol that has a `.fill` form — which
    /// made `message`/`folder`/`gearshape` render as solid color blocks (the
    /// stroke-only `waveform`/`magnifyingglass` were already linear). Overriding
    /// `symbolVariants` to `.none` *on the icon itself* keeps the set linear in
    /// every state; the same override on the enclosing `TabView` is ignored.
    private func linearTabLabel(_ title: LocalizedStringKey, _ systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .environment(\.symbolVariants, .none)
        }
    }

    /// Binding into the per-tab typed route stack.
    private func navPath(_ tab: AppTab) -> Binding<[Route]> {
        Binding(
            get: { model.paths[tab, default: []] },
            set: { model.paths[tab] = $0 }
        )
    }

    private var chatsTab: some View {
        NavigationStack(path: navPath(.chats)) {
            chatsRoot
                .navigationDestination(for: Route.self) { route in
                    routeDestination(route)
                }
        }
    }

    @ViewBuilder
    private var chatsRoot: some View {
        Group {
            if let server = model.selectedServer, let client = model.serverStore.client(for: server) {
                SessionListView(
                    server: server,
                    client: client,
                    selectedConversationID: $model.selectedConversationID,
                    onOpen: { model.open(.conversation($0)) },
                    onNewSession: { model.open(.newSession(NewSessionRequest())) },
                    // The big left title IS the switcher (tappable in place), so
                    // SessionListView owns the title menu here; no inlineLarge +
                    // toolbarTitleMenu on this Group anymore.
                    serverSwitcher: .init(
                        servers: model.serverStore.servers,
                        selection: $model.selectedServerID,
                        onManage: { model.serversSheetPresented = true }
                    ),
                    markedConversationID: model.markedConversationID
                )
                .id(server.id)
            } else if model.selectedServer != nil {
                ColumnPlaceholder(
                    icon: "key.slash",
                    title: "Server Unavailable",
                    message: "This server's token is missing. Edit the server to re-enter it.",
                    actionTitle: "Manage Servers",
                    action: { model.serversSheetPresented = true }
                )
                .navigationTitle(model.selectedServer?.name ?? "Codeg")
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbarTitleMenu { serverSwitcherMenu }
            } else {
                // No server selected (e.g. the active server was just deleted).
                // Server management now lives only in the title menu / this sheet
                // — Settings no longer lists servers — so offer it right here.
                ColumnPlaceholder(
                    icon: "bubble.left.and.bubble.right",
                    title: "No Server Selected",
                    message: "Choose a server, or add a new one.",
                    actionTitle: "Manage Servers",
                    action: { model.serversSheetPresented = true }
                )
                .navigationTitle("Codeg")
            }
        }
    }

    private var projectsTab: some View {
        NavigationStack(path: navPath(.projects)) {
            ProjectListView(
                activity: model.activity,
                client: model.selectedClient(),
                onOpenProject: { model.open(.project($0)) }
            )
            .id(model.selectedServerID)
            .navigationDestination(for: Route.self) { route in
                routeDestination(route)
            }
        }
    }

    private var activityTab: some View {
        NavigationStack(path: navPath(.activity)) {
            ActivityView(
                activity: model.activity,
                client: model.selectedClient(),
                markedConversationID: model.markedConversationID,
                onOpen: { model.open(.conversation($0)) }
            )
            .navigationDestination(for: Route.self) { route in
                routeDestination(route)
            }
        }
    }

    private var settingsTab: some View {
        // Settings navigates over its own `SettingsLeaf` path (not the `Route`
        // stacks): `SettingsView` registers the `.navigationDestination(for:)`,
        // so value-based rows and `codeg://settings/<slug>` both push here.
        NavigationStack(path: $model.settingsPath) {
            SettingsView(store: model.serverStore, selectedServerID: $model.selectedServerID)
        }
    }

    private var searchTab: some View {
        NavigationStack(path: navPath(.search)) {
            SearchView(
                client: model.selectedClient(),
                markedConversationID: model.markedConversationID,
                onOpen: { model.open(.conversation($0)) }
            )
            .id(model.selectedServerID)
            .navigationDestination(for: Route.self) { route in
                routeDestination(route)
            }
        }
    }

    // MARK: - Regular width: three-column split

    private var splitShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SplitSidebar(model: model)
        } content: {
            NavigationStack(path: $model.contentPath) {
                contentRoot
                    .navigationDestination(for: Route.self) { route in
                        routeDestination(route)
                    }
            }
            .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $model.settingsSheetPresented) {
            SettingsSheet(
                store: model.serverStore,
                selectedServerID: $model.selectedServerID,
                path: $model.settingsPath
            )
        }
    }

    @ViewBuilder
    private var contentRoot: some View {
        switch model.sidebarSection {
        case .chats:
            if let server = model.selectedServer, let client = model.serverStore.client(for: server) {
                SessionListView(
                    server: server,
                    client: client,
                    selectedConversationID: $model.selectedConversationID,
                    onNewSession: { model.open(.newSession(NewSessionRequest())) }
                )
                .id(server.id)
            } else {
                ColumnPlaceholder(
                    icon: "bubble.left.and.bubble.right",
                    title: "No Server Selected",
                    message: "Choose a server from the sidebar's title menu."
                )
            }
        case .projects:
            ProjectListView(
                activity: model.activity,
                client: model.selectedClient(),
                onOpenProject: { model.open(.project($0)) }
            )
            .id(model.selectedServerID)
        case .activity:
            ActivityView(
                activity: model.activity,
                client: model.selectedClient(),
                markedConversationID: model.markedConversationID,
                onOpen: { model.open(.conversation($0)) }
            )
        case nil:
            ColumnPlaceholder(
                icon: "sidebar.left",
                title: "Nothing Selected",
                message: "Choose a section in the sidebar."
            )
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let server = model.selectedServer,
           let client = model.serverStore.client(for: server),
           let pending = model.pendingNewSession {
            SessionDetailView(server: server, client: client, newSession: pending,
                              onOpenSession: { model.open(.newSession($0)) })
                .id(pending.id)
        } else if let server = model.selectedServer,
                  let client = model.serverStore.client(for: server),
                  let conversationID = model.selectedConversationID {
            SessionDetailView(server: server, client: client, conversationID: conversationID,
                              onOpenSession: { model.open(.newSession($0)) })
                // Recreate the stateful detail model when the conversation, the
                // server, or its token changes — so it never streams against a
                // stale CodegClient after an in-place server edit / token rotation.
                .id("\(server.id)|\(conversationID)|\(client.token.hashValue)")
        } else {
            ColumnPlaceholder(
                icon: "sparkles",
                title: "Select a Session",
                message: "Pick a session to view its messages and reply to the agent."
            )
        }
    }

    // MARK: - Shared destinations

    /// The single registry mapping `Route`s to screens — every stack (each
    /// compact tab, the iPad content column) registers this, so deep links and
    /// cross-tab opens behave identically everywhere. The tab-bar hide is a
    /// harmless no-op outside a `TabView`.
    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        if let server = model.selectedServer, let client = model.serverStore.client(for: server) {
            switch route {
            case .conversation(let id):
                SessionDetailView(server: server, client: client, conversationID: id,
                                  onOpenSession: { model.open(.newSession($0)) })
                    .id("\(server.id)|\(id)|\(client.token.hashValue)")
                    .toolbar(.hidden, for: .tabBar)
            case .newSession(let request):
                SessionDetailView(server: server, client: client, newSession: request,
                                  onOpenSession: { model.open(.newSession($0)) })
                    .id(request.id)
                    .toolbar(.hidden, for: .tabBar)
            case .project(let id):
                ProjectDetailView(
                    client: client,
                    folderID: id,
                    activity: model.activity,
                    onNewSession: { model.open(.newSession(NewSessionRequest(preselectedFolderID: $0.id))) }
                )
                .id("\(server.id)|folder-\(id)")
            }
        } else {
            ColumnPlaceholder(
                icon: "key.slash",
                title: "Server Unavailable",
                message: "This server's token is missing. Edit the server to re-enter it."
            )
        }
    }

    // MARK: - Server switcher

    /// Title menu shared by the compact Chats root and the iPad sidebar: pick
    /// among saved servers (checkmark via Picker) or open management.
    @ViewBuilder
    private var serverSwitcherMenu: some View {
        Picker("Server", selection: $model.selectedServerID) {
            ForEach(model.serverStore.servers) { server in
                Text(server.name).tag(Optional(server.id))
            }
        }
        Divider()
        // Plain text (no icon): menu button icons render on the trailing edge,
        // which would sit opposite the picker's leading checkmarks.
        Button("Manage Servers…") {
            model.serversSheetPresented = true
        }
    }
}

// MARK: - iPad sidebar

/// The split view's source list: Chats / Projects / Activity, the server title
/// menu, and a gear presenting Settings as a sheet. (Settings was previously
/// unreachable on iPad.)
private struct SplitSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSection) {
            Label("Chats", systemImage: "message")
                .tag(SidebarSection.chats)
            Label("Folders", systemImage: "folder")
                .tag(SidebarSection.projects)
            Label("Activity", systemImage: "waveform")
                .tag(SidebarSection.activity)
                .badge(model.activity.running.count)
        }
        .navigationTitle(model.selectedServer?.name ?? "Codeg")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .toolbarTitleMenu {
            Picker("Server", selection: $model.selectedServerID) {
                ForEach(model.serverStore.servers) { server in
                    Text(server.name).tag(Optional(server.id))
                }
            }
            Divider()
            Button("Manage Servers…") {
                model.serversSheetPresented = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.settingsPath = []
                    model.settingsSheetPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .tint(Theme.accent)
                .accessibilityLabel("Settings")
            }
        }
    }
}

// MARK: - Sheets

/// Server management presented from the title menu — `ServerListView` wrapped
/// in its own stack with a Done button.
private struct ManageServersSheet: View {
    let store: ServerStore
    @Binding var selectedServerID: ServerProfile.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServerListView(store: store, selectedServerID: $selectedServerID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .tint(Theme.accent)
                    }
                }
        }
    }
}

/// Settings presented as a sheet on iPad (compact has its own tab).
private struct SettingsSheet: View {
    let store: ServerStore
    @Binding var selectedServerID: ServerProfile.ID?
    /// Same `[SettingsLeaf]` path the compact tab uses, so a `codeg://settings/<slug>`
    /// deep link opens the sheet already pushed to that pane on iPad too.
    @Binding var path: [SettingsLeaf]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView(store: store, selectedServerID: $selectedServerID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .tint(Theme.accent)
                    }
                }
        }
    }
}

/// Empty-column backdrop with a centered hint, used when nothing is selected.
struct ColumnPlaceholder: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    /// Optional call-to-action (e.g. "Manage Servers" when no server is selected).
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ZStack {
            CodegBackground()
            EmptyStateView(icon: icon, title: title, message: message, actionTitle: actionTitle, action: action)
        }
    }
}

#Preview {
    RootView().preferredColorScheme(.dark)
}
