import SwiftUI

/// Server-side directory browser, presented as a sheet. Browses the *server's*
/// filesystem (the folder we want lives on the remote host, not this device) via
/// `get_home_directory` + `list_directory_entries`, drilling into subdirectories.
/// Confirming returns the current directory's absolute path to `onSelect`.
///
/// Reused by "Open Folder" (select the folder to add) and the Clone sheet's
/// "Browse" (pick the parent directory to clone into).
struct DirectoryBrowserView: View {
    let client: CodegClient
    var title: LocalizedStringKey = "Open Folder"
    var confirmLabel: LocalizedStringKey = "Open This Folder"
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentPath = ""
    @State private var entries: [DirectoryEntry] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                VStack(spacing: 0) {
                    pathBar
                    Divider().overlay(Theme.hairline)
                    content
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await goHome() } } label: {
                        Image(systemName: "house")
                    }
                    .tint(Theme.accent)
                    .disabled(isLoading)
                    .accessibilityLabel("Home")
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
        }
        .presentationDragIndicator(.visible)
        .task { if currentPath.isEmpty { await goHome() } }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button { Task { await goUp() } } label: {
                Image(systemName: "chevron.up")
                    .font(.body.weight(.semibold))
            }
            .codegGlassButtonStyle()
            .tint(Theme.accent)
            .disabled(isRoot || isLoading)
            .accessibilityLabel("Up")

            Text(currentPath.isEmpty ? "…" : currentPath)
                .font(.mono(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            LoadingView(label: "Loading…")
        } else if let error {
            InlineErrorView(message: error) {
                Task { await navigate(to: currentPath) }
            }
        } else if entries.isEmpty {
            EmptyStateView(
                icon: "folder",
                title: "No Subfolders",
                message: "This folder has no subfolders. Use the button below to choose it."
            )
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(entries) { entry in
                    Button { Task { await navigate(to: entry.path) } } label: {
                        GlassRow {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 22)
                                Text(entry.name)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(entry.hasChildren ? Theme.textTertiary : .clear)
                            }
                        }
                        // Make the WHOLE row (icon, the spacer gap, padding) a hit
                        // target — the glass background alone isn't a reliable tap
                        // shape, which left parts of a row untappable.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
    }

    private var confirmBar: some View {
        PrimaryGlassButton(title: confirmLabel, systemImage: "checkmark") {
            onSelect(currentPath)
            dismiss()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .disabled(currentPath.isEmpty || isLoading)
    }

    // MARK: - Navigation

    /// At root when the parent of the current path is itself (POSIX "/").
    private var isRoot: Bool {
        let parent = (currentPath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == currentPath
    }

    private func goHome() async {
        do {
            let home = try await client.homeDirectory()
            await navigate(to: home)
        } catch {
            self.error = message(for: error)
        }
    }

    private func goUp() async {
        let parent = (currentPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != currentPath else { return }
        await navigate(to: parent)
    }

    private func navigate(to path: String) async {
        currentPath = path
        isLoading = true
        error = nil
        do {
            entries = try await client.listDirectoryEntries(path: path)
        } catch {
            entries = []
            self.error = message(for: error)
        }
        isLoading = false
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
