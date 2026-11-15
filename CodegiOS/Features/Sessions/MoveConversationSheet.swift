import SwiftUI

/// "Move to…" for one conversation (web `MoveToFolderMenu` +
/// `MoveConversationDialog`): the server's OPEN folders, read afresh (one closed
/// since the list loaded is no destination), less the current one; picking one
/// asks to confirm with what changes. `onConfirm` gets the folder and the name
/// to say it by; the host runs the move and tells its outcome — nothing is
/// optimistic, the server judges each conversation.
struct MoveConversationSheet: View {
    let conversation: ConversationSummary
    let client: CodegClient
    let onConfirm: (FolderDetail, String) -> Void

    @State private var targets: [FolderDetail]?
    /// Every folder, to name a worktree by its repo and find a chat's scratch
    /// directory.
    @State private var allFolders: [FolderDetail] = []
    @State private var loadError: String?
    @State private var confirming: FolderDetail?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $confirming) { folder in
                MoveConfirmationView(
                    conversation: conversation,
                    folder: folder,
                    label: ConversationMove.label(for: folder, in: allFolders),
                    chatFilesPath: chatFilesPath,
                    onMove: { label in
                        onConfirm(folder, label)
                        dismiss()
                    }
                )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .task { await load() }
    }

    /// A chat's files stay in its scratch directory: said in the confirmation.
    private var chatFilesPath: String? {
        guard conversation.kind == .chat else { return nil }
        return allFolders.first { $0.id == conversation.folderId }?.path
    }

    private func load() async {
        async let openRequest = client.listOpenFolders()
        async let allRequest = client.listFolders()
        do {
            let open = try await openRequest
            allFolders = (try? await allRequest) ?? open
            targets = ConversationMove.targets(open: open, currentFolderID: conversation.folderId)
        } catch {
            guard !Task.isCancelled else { return }
            loadError = ConversationMove.failure(error)
            targets = []
        }
    }

    @ViewBuilder
    private var content: some View {
        if let targets {
            List {
                Section {
                    (conversation.trimmedTitle.map { Text(verbatim: $0) } ?? Text("Untitled conversation"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .listRowBackground(Color.clear)
                    if let loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    } else if targets.isEmpty {
                        Text("No other open folder")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if !targets.isEmpty {
                    Section {
                        ForEach(targets) { folder in
                            targetRow(folder)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else {
            ProgressView().tint(Theme.accent)
        }
    }

    private func targetRow(_ folder: FolderDetail) -> some View {
        Button {
            confirming = folder
        } label: {
            HStack(spacing: 12) {
                Image(systemName: folder.isWorktree ? "arrow.triangle.branch" : "folder")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ConversationMove.label(for: folder, in: allFolders))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    // The path tells two same-named repos apart.
                    Text(verbatim: folder.path)
                        .font(.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The confirmation the web's dialog gives: which folder, what changes from
/// the next message on, and — for a chat — that its files stay behind.
private struct MoveConfirmationView: View {
    let conversation: ConversationSummary
    let folder: FolderDetail
    let label: String
    let chatFilesPath: String?
    let onMove: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                GlassCard(cornerRadius: Theme.Radius.md, padding: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: folder.isWorktree ? "arrow.triangle.branch" : "folder")
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Text(verbatim: folder.path)
                                .font(.mono(11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("From the next message on, the agent works in this folder; the history stays as it is. If the agent can't resume the session here, you'll be offered to reload it or start a new session.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    if let chatFilesPath {
                        Text("Files created during the chat stay in its scratch directory \(chatFilesPath); they are not moved into the folder.")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

                FlatPrimaryButton(title: "Move", systemImage: "folder.badge.plus") {
                    onMove(label)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(CodegBackground())
        .navigationTitle("Move conversation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: Text {
        if let title = conversation.trimmedTitle {
            return Text("“\(title)” will be moved to this folder:")
        }
        return Text("“\(String(localized: "Untitled conversation"))” will be moved to this folder:")
    }
}
