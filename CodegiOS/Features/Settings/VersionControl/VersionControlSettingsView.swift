import SwiftUI

/// Version Control: git availability + custom path override, and GitHub accounts
/// (add/edit with token validation, set-default, delete).
struct VersionControlSettingsView: View {
    let client: CodegClient?
    @State private var model: VersionControlSettingsModel
    @State private var editorRoute: EditorRoute?
    @State private var pendingDelete: GitHubAccount?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum EditorRoute: Identifiable {
        case add
        case edit(GitHubAccount)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let a): "edit-\(a.id)"
            }
        }
    }

    init(client: CodegClient?) {
        self.client = client
        _model = State(initialValue: VersionControlSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Version Control", compact: horizontalSizeClass == .compact)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorRoute = .add } label: { Image(systemName: "plus") }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add GitHub Account")
            }
        }
        .sheet(item: $editorRoute) { route in
            switch route {
            case .add:
                GitHubAccountEditorSheet(editing: nil, client: client) { account, token in
                    try await model.upsert(account, token: token)
                }
            case .edit(let account):
                GitHubAccountEditorSheet(editing: account, client: client) { acct, token in
                    try await model.upsert(acct, token: token)
                }
            }
        }
        .confirmationDialog(
            "Remove Account",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { account in
            Button("Remove @\(account.username)", role: .destructive) {
                Task { await model.delete(account) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Removes @\(account.username) (\(account.host)) and its stored token.")
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView(label: "Loading…")
        case .failed(let message):
            InlineErrorView(message: message) { Task { await model.load() } }
        case .loaded:
            ScrollView {
                VStack(spacing: 18) {
                    if let error = model.refreshError {
                        RefreshErrorBanner(message: error, retry: { Task { await model.load() } }, dismiss: { model.refreshError = nil })
                    }
                    gitSection
                    accountsSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    private var gitSection: some View {
        EditorSection(title: "Git", footer: "Override the git executable path if it isn’t auto-detected.") {
            HStack(spacing: 10) {
                Image(systemName: (model.git?.installed ?? false) ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle((model.git?.installed ?? false) ? Color(red: 0.30, green: 0.78, blue: 0.38) : Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gitStatusTitle).foregroundStyle(Theme.textPrimary)
                    if let path = model.git?.path, !path.isEmpty {
                        Text(path).font(.mono(12)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            Divider().overlay(Theme.hairline)
            FieldRow(label: "Custom git path") {
                TextField("/usr/bin/git", text: $model.customPath)
                    .font(.mono(15)).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
            }
            if let test = model.testResult {
                Text(test.installed ? "Found git \(test.version.map { "v\($0)" } ?? "") at that path." : "No git found at that path.")
                    .font(.caption)
                    .foregroundStyle(test.installed ? Color(red: 0.30, green: 0.78, blue: 0.38) : Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                Button { Task { await model.testCustomPath() } } label: {
                    HStack(spacing: 6) {
                        if model.testing { ProgressView().controlSize(.small) }
                        Text("Test")
                    }
                }
                .codegGlassButtonStyle().tint(Theme.accent)
                .disabled(model.testing || model.customPath.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Save Path") { Task { await model.saveCustomPath() } }
                    .codegGlassButtonStyle(prominent: true).tint(Theme.accent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        EditorSection(title: "GitHub Accounts") {
            if model.accounts.isEmpty {
                Text("No accounts. Add one to authenticate clones and pushes.")
                    .font(.subheadline).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 13)
            } else {
                ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    AccountRow(account: account)
                        .contentShape(.rect)
                        .onTapGesture { editorRoute = .edit(account) }
                        .contextMenu {
                            Button { editorRoute = .edit(account) } label: { Label("Edit", systemImage: "pencil") }
                            if !account.isDefault {
                                Button { Task { await model.setDefault(account) } } label: { Label("Set as Default", systemImage: "star") }
                            }
                            Divider()
                            Button(role: .destructive) { pendingDelete = account } label: { Label("Remove", systemImage: "trash") }
                        }
                }
            }
        }
    }

    private var gitStatusTitle: LocalizedStringKey {
        guard let git = model.git else { return "Git" }
        if git.installed { return "Installed\(git.version.map { " · v\($0)" } ?? "")" }
        return "Not installed"
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                .padding(.horizontal, 24).padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }
}

private struct AccountRow: View {
    let account: GitHubAccount

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: account.avatarUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.surfaceStroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(account.username)").font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(account.host).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if account.isDefault {
                Text("DEFAULT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.16), in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}
