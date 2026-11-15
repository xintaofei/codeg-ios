import SwiftUI
import Observation

/// Fetches the connected server's reported version via the `health` endpoint so
/// Settings/About can show a live number rather than a hardcoded one. Mirrors
/// `ServerStatusModel`'s probe style but for a single, on-demand lookup.
@MainActor
@Observable
final class ServerVersionModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(String)
        case unavailable
    }

    private(set) var state: State = .idle
    /// The server the loaded version is from.
    @ObservationIgnored private var loadedFrom: String?

    /// Probe `health()` on the given client. A nil client (no server selected or
    /// unresolved token) resolves straight to `.unavailable`. The version once
    /// read stays: Settings asks again each time its tab comes back, and a
    /// server's version doesn't change under a running app often enough to
    /// redraw the page for it.
    func load(_ client: CodegClient?) async {
        guard let client else {
            loadedFrom = nil
            state = .unavailable
            return
        }
        let source = "\(client.baseURL.absoluteString)|\(client.token)"
        if case .loaded = state, loadedFrom == source { return }
        state = .loading
        do {
            let health = try await client.health()
            state = .loaded(health.version)
            loadedFrom = source
        } catch {
            state = .unavailable
        }
    }
}

/// About / version detail, pushed from the Settings identity card. Holds the app
/// description plus a labelled list of versions: the app's own (from the bundle)
/// and the connected server's (fetched via `health`).
struct AboutView: View {
    let versionModel: ServerVersionModel
    let serverName: String?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    descriptionCard
                    versionCard
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cards

    private var headerCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 60, height: 60)
                    .background(
                        Theme.accentDim,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codeg")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("codeg agent client for iOS")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var descriptionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("About")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Browse and drive your codeg servers' agent sessions from iOS — watch tasks live, reply while the agent streams, and start new work in any folder.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var versionCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                infoRow(label: "App Version") {
                    Text("\(appVersion) (\(build))")
                        .font(.mono(13))
                        .foregroundStyle(Theme.textPrimary)
                }
                rowDivider
                infoRow(label: "Server") {
                    Text(serverName ?? "—")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                rowDivider
                infoRow(label: "Server Version") {
                    serverVersionValue
                }
            }
        }
    }

    @ViewBuilder
    private var serverVersionValue: some View {
        switch versionModel.state {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(Theme.textSecondary)
                Text("Checking…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .loaded(let version):
            Text("v\(version)")
                .font(.mono(13))
                .foregroundStyle(Theme.textPrimary)
        case .unavailable:
            Text("Unavailable")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Pieces

    private func infoRow(label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            value()
        }
        .padding(.vertical, 9)
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline)
    }
}
