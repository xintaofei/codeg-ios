import SwiftUI

/// Centered empty-state with an optional primary action.
struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            // A branded accent tile (the shared DS treatment) rather than a bare
            // grey glyph — an empty screen should feel like an invitation in the
            // app's voice, not a placeholder.
            AccentIconTile(symbol: icon, size: 60)
                .padding(.bottom, 2)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .codegGlassButtonStyle()
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .padding(32)
    }
}

/// Centered progress indicator with a caption.
struct LoadingView: View {
    var label: LocalizedStringKey = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
    }
}

/// A compact, dismissible error strip shown above a still-populated list when a
/// refresh fails, so stale rows stay visible but the failure isn't silent.
struct RefreshErrorBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)

            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry", action: retry)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .codegGlassEffect(
            tint: Theme.danger.opacity(0.16),
            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        )
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(0.35))
    }
}

/// Inline error card with a retry affordance.
struct InlineErrorView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.danger)
            Text("Something went wrong")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try Again", action: retry)
                    .codegGlassButtonStyle()
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 340)
        .padding(28)
    }
}
