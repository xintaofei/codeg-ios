import SwiftUI

/// A folder's commit history (`git_log`): the most recent commits, each a row of
/// subject + author/time/hash + change counts. Tapping a commit pushes
/// ``CommitDetailView``. Embedded in the Commits tab of ``ProjectDetailView``.
struct FolderCommitsView: View {
    let model: FolderGitModel

    private var client: CodegClient { model.client }
    private var rootPath: String { model.rootPath }

    /// How many commits to request — plenty for a phone, fast for local git.
    private static let limit = 50

    @State private var entries: [GitLogEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var notARepo = false
    @State private var loaded = false
    @State private var hasUpstream = false
    @State private var pushInfo: GitPushInfo?

    var body: some View {
        content
            .task {
                if !loaded { await load() }
                await loadPushInfo()
            }
            // After a remote op (push/pull/fetch) the pushed flags + push info change.
            .onChange(of: model.reloadToken) {
                Task {
                    await load(force: true)
                    await loadPushInfo()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !loaded {
            LoadingView(label: "Loading history…")
        } else if notARepo {
            // A folder can stop being a repo after a successful load (e.g. its
            // .git was removed); the non-repo state takes precedence over any
            // stale commits, and stays pull-to-refreshable so it can recover.
            ScrollView { NotAGitRepoState() }
                .scrollContentBackground(.hidden)
                .refreshable { await load(force: true) }
        } else if let error, !loaded {
            InlineErrorView(message: error) { Task { await load() } }
        } else {
            // Loaded (possibly empty) — one refreshable scroll so an empty history
            // is still pull-to-refreshable and a failed refresh surfaces a banner.
            loadedList
        }
    }

    private var loadedList: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Operation status strip (busy / result banner) above everything.
                GitStatusStrip(model: model)
                    .padding(.bottom, model.isBusy || model.banner != nil ? 4 : 0)

                // Branch + remote sync actions (pull / push / fetch).
                if loaded && !notARepo {
                    GitSyncHeader(
                        model: model,
                        pushInfo: pushInfo,
                        unpushedCount: unpushedCount,
                        onRefresh: { Task { await load(force: true) } }
                    )
                }

                // Keep what's shown but surface a failed refresh — outside the
                // grouped card (its own danger-tinted surface).
                if let error, loaded {
                    RefreshErrorBanner(message: error, retry: { Task { await load(force: true) } }, dismiss: { self.error = nil })
                }
                if entries.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No Commits",
                        message: "This repository has no commit history yet."
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    // One continuous grouped surface (capped at 50, so a plain
                    // VStack inside the card is fine) instead of per-row cards.
                    // Flat (no glass shadow) so the white list sits flat on the bg.
                    FlatCard(cornerRadius: Theme.Radius.lg) {
                        VStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 {
                                    InsetDivider(leading: SettingsRowMetrics.hInset)
                                }
                                NavigationLink {
                                    CommitDetailView(client: client, rootPath: rootPath, entry: entry)
                                } label: {
                                    CommitRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if entries.count >= Self.limit {
                        Text("Showing the latest \(Self.limit) commits")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load(force: true) }
    }

    /// Unpushed commits — meaningful only when the branch tracks a remote.
    private var unpushedCount: Int {
        hasUpstream ? entries.filter { $0.pushed == false }.count : 0
    }

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        error = nil
        notARepo = false
        do {
            let result = try await client.gitLog(path: rootPath, limit: Self.limit)
            entries = result.entries
            hasUpstream = result.hasUpstream
            loaded = true
        } catch {
            if (error as? APIError)?.isNotAGitRepository == true {
                notARepo = true
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Branch + remotes for the sync header. Best-effort — a non-repo or a failure
    /// just leaves the header without a remote target (Push disabled).
    private func loadPushInfo() async {
        pushInfo = try? await client.gitPushInfo(path: rootPath)
    }
}

// MARK: - Sync header

/// The remote-sync action bar atop the Commits tab: current branch → remote, an
/// unpushed badge, and Pull / Push / Fetch actions driven by ``FolderGitModel``.
private struct GitSyncHeader: View {
    let model: FolderGitModel
    let pushInfo: GitPushInfo?
    let unpushedCount: Int
    let onRefresh: () -> Void

    /// We know there's no remote only once push info has loaded and is empty;
    /// until then Push stays enabled (the op surfaces a clear error if it can't).
    private var hasNoRemote: Bool {
        guard let pushInfo else { return false }
        return pushInfo.uniqueRemotes.isEmpty
    }

    private var remoteLabel: String? {
        pushInfo?.trackingRemote ?? pushInfo?.uniqueRemotes.first?.name
    }

    var body: some View {
        // A flat header band (no card) so the only rounded surface on the tab is
        // the commits list below — avoids the "stacked cards" look. The branch →
        // remote line orients; the glass action buttons sit directly on the
        // backdrop like a toolbar.
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(pushInfo?.branch ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let remoteLabel {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(remoteLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if unpushedCount > 0 {
                    Label("\(unpushedCount) unpushed", systemImage: "arrow.up.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.warning)
                        .labelStyle(.titleAndIcon)
                }
            }

            HStack(spacing: 10) {
                AccentPillButton(title: "Pull", systemImage: "arrow.down") { Task { await model.pull() } }
                    .disabled(model.isBusy)
                AccentPillButton(title: "Push", systemImage: "arrow.up", prominent: unpushedCount > 0) { Task { await model.push() } }
                    .disabled(model.isBusy || hasNoRemote)
                Spacer(minLength: 8)
                overflowMenu
                    .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Overflow (Fetch / Refresh), a soft accent capsule matching the sync pills.
    private var overflowMenu: some View {
        Menu {
            Button { Task { await model.fetch() } } label: { Label("Fetch", systemImage: "arrow.down.circle") }
            Button(action: onRefresh) { Label("Refresh", systemImage: "arrow.clockwise") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 35)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                .contentShape(Capsule())
        }
    }
}

/// Shown in the Changes/Commits tabs when the folder isn't under git version
/// control (the server's git endpoints return `not_a_git_repository`). Keeps the
/// tabs honest without surfacing a scary error.
struct NotAGitRepoState: View {
    var body: some View {
        EmptyStateView(
            icon: "arrow.triangle.branch",
            title: "Not a Git Repository",
            message: "This folder isn't under git version control, so there's nothing to show here. Browse its files in the Files tab."
        )
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

// MARK: - Row

/// One commit: subject on top, then author · relative time on the left and the
/// short hash + change counts on the right. A cloud glyph flags push state when
/// the branch tracks a remote. Borderless: the enclosing grouped card draws the
/// surface.
private struct CommitRow: View {
    @Environment(\.locale) private var locale
    let entry: GitLogEntry

    var body: some View {
        GroupedRow(vInset: 11) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.subject)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let pushed = entry.pushed {
                        Image(systemName: pushed ? "cloud.fill" : "cloud")
                            .font(.system(size: 10))
                            .foregroundStyle(pushed ? Theme.accent : Theme.textTertiary)
                            .help(pushed ? "Pushed" : "Not pushed")
                    }
                }

                HStack(spacing: 6) {
                    Text(entry.author)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let date = entry.authoredDate {
                        Text("·").font(.caption2).foregroundStyle(Theme.textTertiary)
                        Text(RelativeTime.string(from: date, locale: locale))
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }

                    Spacer(minLength: 8)

                    ChangeCounts(additions: entry.totalAdditions, deletions: entry.totalDeletions)

                    Text(entry.hash)
                        .font(.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .fixedSize()
                }
            }
        }
    }
}

/// Compact `+adds −dels` pair, each omitted when zero.
struct ChangeCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 {
                Text("+\(additions)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DiffPalette.addText)
            }
            if deletions > 0 {
                Text("−\(deletions)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DiffPalette.delText)
            }
        }
        .fixedSize()
    }
}

// MARK: - Commit detail

/// A single commit's full message, metadata, and diff. The file list comes from
/// the already-loaded `git_log` entry; the unified diff is fetched on appear via
/// `git_show_diff` and rendered with the shared ``DiffView``.
struct CommitDetailView: View {
    let client: CodegClient
    let rootPath: String
    let entry: GitLogEntry

    @State private var diffFiles: [DiffFile]?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    summaryLine
                    diffSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(entry.hash)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDiff() }
    }

    private var headerCard: some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.subject)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Text(entry.author)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let date = entry.authoredDate {
                        Text("·").font(.caption).foregroundStyle(Theme.textTertiary)
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if let pushed = entry.pushed {
                        Spacer(minLength: 6)
                        Label(pushed ? "Pushed" : "Local", systemImage: pushed ? "cloud.fill" : "cloud")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(pushed ? Theme.accent : Theme.textTertiary)
                    }
                }

                // Full hash, tappable to copy.
                Button {
                    UIPasteboard.general.string = entry.fullHash
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "number")
                            .font(.system(size: 9, weight: .semibold))
                        Text(entry.fullHash)
                            .font(.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summaryLine: some View {
        HStack(spacing: 8) {
            Text("\(entry.files.count) files changed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 6)
            ChangeCounts(additions: entry.totalAdditions, deletions: entry.totalDeletions)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var diffSection: some View {
        if isLoading {
            LoadingView(label: "Loading diff…")
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if let diffFiles, !diffFiles.isEmpty {
            DiffView(files: diffFiles)
        } else if let error {
            // Diff failed — fall back to the file list we already have from git_log.
            VStack(alignment: .leading, spacing: 8) {
                fileList
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            // Parsed empty (e.g. merge commit with no textual diff): show files.
            fileList
        }
    }

    /// The commit's touched files as status-badged rows (fallback when the diff
    /// isn't renderable).
    private var fileList: some View {
        VStack(spacing: 8) {
            ForEach(entry.files, id: \.path) { file in
                HStack(spacing: 10) {
                    ChangeBadge(change: file.change)
                    Text(PathFormat.short(file.path))
                        .font(.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChangeCounts(additions: file.additions, deletions: file.deletions)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.codeSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .hairlineBorder(Theme.Radius.sm)
            }
        }
    }

    private func loadDiff() async {
        guard diffFiles == nil else { return }
        isLoading = true
        error = nil
        do {
            let raw = try await client.gitShowDiff(path: rootPath, commit: entry.fullHash)
            diffFiles = UnifiedDiff.parse(raw) ?? []
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Shared badge

/// A small letter badge tinted by git change category (A/M/D/R/…).
struct ChangeBadge: View {
    let change: GitChange

    var body: some View {
        Text(change.letter)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(change.tint)
            .frame(width: 18, height: 18)
            .background(change.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(change.label)
    }
}
