import SwiftUI

/// The git branch selector, pushed from the agent options sheet. Lists the
/// folder's local + remote branches (searchable), checks one out on tap, and can
/// create a new branch — mirroring codeg web's below-input branch picker. Branches
/// already checked out in another worktree are shown disabled (git can't check the
/// same branch out twice). All work routes through `SessionBranchConfig`'s
/// closures, which call the view model on the main actor.
struct BranchPickerView: View {
    let config: SessionBranchConfig
    /// Closes the whole options sheet (passed from `AgentOptionsButton`) so we can
    /// navigate to a worktree session instead of staying behind the sheet.
    var dismissSheet: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var list: GitBranchList?
    @State private var isLoading = true
    @State private var search = ""
    /// The current branch — seeded from the config, advanced as the user switches.
    @State private var current: String?
    /// The branch currently being checked out (drives its row spinner + locks others).
    @State private var switching: String?

    @State private var showNewBranch = false
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                newBranchSection

                if isLoading {
                    loadingRow
                } else if let list {
                    branchSections(list)
                } else {
                    emptyRow
                }
            }
            .padding(16)
        }
        .background(CodegBackground())
        .navigationTitle("Branch")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            current = config.current
            list = await config.load()
            isLoading = false
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func branchSections(_ list: GitBranchList) -> some View {
        let worktree = Set(list.worktreeBranches)
        let local = filtered(list.local)
        let remote = filtered(list.remote)

        if local.isEmpty && remote.isEmpty {
            emptyRow
        } else {
            if !local.isEmpty {
                section(Text("Local"), names: local, worktree: worktree, isRemote: false)
            }
            if !remote.isEmpty {
                section(Text("Remote"), names: remote, worktree: worktree, isRemote: true)
            }
        }
    }

    private func section(_ title: Text, names: [String], worktree: Set<String>, isRemote: Bool) -> some View {
        OptionSection(title: title) {
            ForEach(Array(names.enumerated()), id: \.element) { index, name in
                if index > 0 { separator }
                // A remote ref (`origin/x`) checks out the local branch `x`; match
                // the worktree-occupancy + current checkmark against that target.
                let target = isRemote ? Self.stripRemotePrefix(name) : name
                branchRow(name, target: target, occupied: worktree.contains(target) && target != current, isRemote: isRemote)
            }
        }
    }

    private func branchRow(_ name: String, target: String, occupied: Bool, isRemote: Bool) -> some View {
        Button {
            Task { await switchTo(display: name, target: target, isRemote: isRemote) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(occupied ? Theme.textTertiary : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.mono(13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if occupied {
                        Text("Checked out in another worktree")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                if switching == name {
                    ProgressView().controlSize(.small)
                } else if target == current {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(occupied || switching != nil)
        .opacity(occupied ? 0.5 : 1)
    }

    // MARK: - New branch

    @ViewBuilder
    private var newBranchSection: some View {
        if showNewBranch {
            VStack(alignment: .leading, spacing: 10) {
                TextField("new-branch-name", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.mono(13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                HStack(spacing: 12) {
                    if let current {
                        Text("From \(current)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { showNewBranch = false; newName = "" }
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Button { Task { await create() } } label: {
                        if creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Create").font(.callout.weight(.semibold))
                        }
                    }
                    .foregroundStyle(Theme.accent)
                    .disabled(trimmedNewName.isEmpty || creating)
                }
            }
            .padding(14)
            .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .hairlineBorder(Theme.Radius.md)
        } else {
            Button { showNewBranch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("New Branch")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .codegGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .hairlineBorder(Theme.Radius.md)
        }
    }

    // MARK: - Chrome

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            TextField("Filter branches", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text("Loading branches…")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyRow: some View {
        Text(search.isEmpty ? "No branches found." : "No branches match “\(search)”.")
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.75)
            .padding(.leading, 14)
    }

    // MARK: - Actions

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `display` is the row's label (full remote name for a remote row); `target`
    /// is the branch actually switched to (the local name).
    private func switchTo(display: String, target: String, isRemote: Bool) async {
        guard switching == nil else { return }
        switching = display
        let outcome = await config.switchTo(target, isRemote)
        switching = nil
        switch outcome {
        case .switchedInPlace:
            current = target
            dismiss()
        case .noop:
            dismiss()
        case .openSession(let folderId):
            // The branch lives in another worktree → close the whole sheet, then
            // open a new draft session there (the current conversation stays put).
            // Defer the navigation one runloop tick so the sheet dismissal commits
            // first — pushing onto the presenter's stack in the same tick can let
            // the sheet linger above the pushed destination.
            dismissSheet()
            Task { @MainActor in config.onOpenSession?(folderId) }
        case .failed:
            break  // a `notice` was surfaced by the view model
        }
    }

    /// `origin/feature/x` → `feature/x` (drop the leading remote-name segment),
    /// matching the web's `replace(/^[^/]+\//, "")`.
    private static func stripRemotePrefix(_ remote: String) -> String {
        guard let slash = remote.firstIndex(of: "/") else { return remote }
        return String(remote[remote.index(after: slash)...])
    }

    private func create() async {
        guard !trimmedNewName.isEmpty else { return }
        creating = true
        let ok = await config.create(trimmedNewName, current)
        creating = false
        if ok { dismiss() }
    }

    private func filtered(_ names: [String]) -> [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return names }
        return names.filter { $0.lowercased().contains(q) }
    }
}
