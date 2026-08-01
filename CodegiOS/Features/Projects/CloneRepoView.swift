import SwiftUI

/// Clone a git repository onto the server, presented as a sheet from the Folders
/// tab "+" menu. Mirrors codeg's desktop Clone dialog: enter a repo URL + a
/// destination parent directory (browsable), clone into `<dir>/<repoName>`, then
/// register the result via `open_folder` so it shows up as a folder.
struct CloneRepoView: View {
    let client: CodegClient
    /// Called after a successful clone so the caller can refresh its folder list.
    let onCloned: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var url = ""
    @State private var targetDir = ""
    @State private var username = ""
    @State private var password = ""
    @State private var browserOpen = false
    @State private var cloning = false
    @State private var error: String?

    private enum Field: Hashable { case url, dir, username, password }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        repoSection
                        destinationSection
                        credentialsSection
                        if let error {
                            ErrorBanner(message: error)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Clone Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                        .disabled(cloning)
                }
            }
            .safeAreaInset(edge: .bottom) { cloneBar }
            .sheet(isPresented: $browserOpen) {
                DirectoryBrowserView(
                    client: client,
                    title: "Choose Directory",
                    confirmLabel: "Select This Folder",
                    onSelect: { targetDir = $0 }
                )
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var repoSection: some View {
        EditorSection(title: "Repository") {
            FieldRow(label: "Repository URL") {
                TextField("https://github.com/owner/repo.git", text: $url)
                    .font(.mono(15))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .url)
                    .onSubmit { focusedField = .dir }
                    .disabled(cloning)
            }
        }
    }

    private var destinationSection: some View {
        EditorSection(
            title: "Destination",
            footer: clonePathPreview.map { LocalizedStringKey(stringLiteral: $0) }
        ) {
            FieldRow(label: "Parent Directory") {
                HStack(spacing: 8) {
                    TextField("/Users/you/Code", text: $targetDir)
                        .font(.mono(15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .focused($focusedField, equals: .dir)
                        .disabled(cloning)
                    Button {
                        focusedField = nil
                        browserOpen = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .codegGlassButtonStyle()
                    .tint(Theme.accent)
                    .disabled(cloning)
                    .accessibilityLabel("Browse")
                }
            }
        }
    }

    private var credentialsSection: some View {
        EditorSection(
            title: "Authentication",
            footer: "Only needed for private repositories. Use a personal access token as the password."
        ) {
            FieldRow(label: "Username") {
                TextField("Optional", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .disabled(cloning)
            }
            Divider().overlay(Theme.hairline)
            FieldRow(label: "Password / Token") {
                SecureField("Optional", text: $password)
                    .font(.mono(15))
                    .textContentType(.password)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .password)
                    .disabled(cloning)
            }
        }
    }

    private var cloneBar: some View {
        PrimaryGlassButton(title: "Clone", systemImage: "square.and.arrow.down", isLoading: cloning) {
            focusedField = nil
            Task { await clone() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .disabled(!canClone)
    }

    // MARK: - Derived

    /// Repo name from the URL: strip a trailing `.git`, take the last path part.
    private var repoName: String {
        var name = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? "repo" : last
    }

    /// Full clone destination = `<parent>/<repoName>`.
    private var fullPath: String {
        let dir = targetDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return "" }
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return "\(base)/\(repoName)"
    }

    private var clonePathPreview: String? {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fullPath.isEmpty else { return nil }
        return "Clones into \(fullPath)"
    }

    private var canClone: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !targetDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cloning
    }

    // MARK: - Action

    private func clone() async {
        let repoURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = fullPath
        guard !repoURL.isEmpty, !path.isEmpty else { return }

        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials: GitCredentials? =
            (user.isEmpty && password.isEmpty) ? nil : GitCredentials(username: user, password: password)

        cloning = true
        error = nil
        do {
            try await client.cloneRepository(url: repoURL, targetDir: path, credentials: credentials)
            // Register the freshly cloned directory as a workspace folder.
            _ = try await client.openFolder(path: path)
            cloning = false
            onCloned()
            dismiss()
        } catch {
            cloning = false
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Inline error banner for the clone sheet.
private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(0.35))
    }
}
