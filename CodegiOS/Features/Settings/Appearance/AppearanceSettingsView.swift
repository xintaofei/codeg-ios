import SwiftUI

/// Appearance settings: the theme mode (Light / Dark / System) and the accent
/// color scheme. Both are purely local (device-scoped) preferences held in
/// `AppearanceStore`, which is injected into the environment by `RootView`.
/// Changing either recolors the whole app live — mode via `.preferredColorScheme`
/// and accent via the `\.codegAccent` trait bridge. This screen's own accent-tinted
/// bits (the theme rows and the preview) resolve the accent explicitly (see
/// `resolvedAccent`) instead of through that trait, so they recolor correctly even
/// when the screen is presented in a separate hosting controller — the iPad
/// Settings sheet — which the bridged trait can't reach.
struct AppearanceSettingsView: View {
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    /// Per device, off by default — the web's `workspace:chat-html-rendering`.
    @AppStorage(ChatHtmlPreference.key) private var chatHtmlRendering = false

    // The accent resolved straight from the store + the standard color-scheme
    // trait — NOT via `Theme.accent`, which reads the bridged `\.codegAccent`
    // trait. That bridged trait doesn't cross into a separately-presented hosting
    // controller, so on iPad — where Settings is a sheet — accent-tinted bits on
    // this page would stay stuck at the default palette while the swatch grid
    // (which reads `appearance.accent` directly) updates. `colorScheme` is a
    // standard trait that *does* propagate into sheets, so these stay correct in
    // every presentation context. Used by the theme rows and the preview.
    private var resolvedAccent: Color { appearance.accent.fill(dark: colorScheme == .dark) }
    private var resolvedOnAccent: Color { appearance.accent.onColor(dark: colorScheme == .dark) }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    themeSection
                    accentSection
                    previewSection
                    chatHtmlSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .screenTitle("Appearance", compact: horizontalSizeClass == .compact)
    }

    // MARK: - Theme mode

    private var themeSection: some View {
        EditorSection(
            title: "Theme",
            footer: "“System” follows your device's Light / Dark setting."
        ) {
            ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 { InsetDivider(leading: 16) }
                SelectableRow(symbol: mode.symbol, title: mode.titleKey,
                              isSelected: appearance.mode == mode, tint: resolvedAccent) {
                    appearance.mode = mode
                }
            }
        }
    }

    // MARK: - Accent

    private var accentSection: some View {
        EditorSection(
            title: "Accent Color",
            footer: "The signature tint used across buttons, highlights, and icons."
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 66), spacing: 14)],
                spacing: 18
            ) {
                ForEach(AccentPalette.allCases) { palette in
                    swatch(palette)
                }
            }
            .padding(16)
        }
    }

    private func swatch(_ palette: AccentPalette) -> some View {
        let isSelected = appearance.accent == palette
        return Button {
            appearance.accent = palette
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(palette.swatch)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    if isSelected {
                        Circle()
                            .strokeBorder(Theme.textPrimary, lineWidth: 2)
                            .frame(width: 54, height: 54)
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(palette.onColor(dark: colorScheme == .dark))
                    }
                }
                .frame(width: 54, height: 54)
                Text(palette.titleKey)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }

    // MARK: - Chat HTML

    /// The web's "Chat HTML rendering" section (`ChatHtmlSettingsSection`).
    private var chatHtmlSection: some View {
        EditorSection(
            title: "Chat HTML rendering",
            footer: "Display self-contained HTML/CSS cards and diagrams directly in AI replies. Model scripts and external resources are blocked."
        ) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(resolvedAccent)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Toggle("Render HTML in chat", isOn: $chatHtmlRendering)
                    .tint(resolvedAccent)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Live preview

    private var previewSection: some View {
        // Explicitly resolved (see `resolvedAccent`) so the sample chip, button,
        // and accent text recolor even inside the iPad Settings sheet, which the
        // bridged `Theme.accent` trait can't reach.
        let accent = resolvedAccent
        let onAccent = resolvedOnAccent
        return EditorSection(title: "Preview") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    FilterChip(title: "Selected", systemImage: "checkmark",
                               isSelected: true, tint: accent, onTint: onAccent) {}
                    FilterChip(title: "Idle", isSelected: false) {}
                    Spacer(minLength: 0)
                }
                PrimaryGlassButton(title: "Primary Action", systemImage: "sparkles",
                                   tint: accent, onTint: onAccent) {}
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                    Text("Accent text & icons")
                        .foregroundStyle(accent)
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(16)
        }
    }
}
