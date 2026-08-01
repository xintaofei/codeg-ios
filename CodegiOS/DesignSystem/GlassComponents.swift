import SwiftUI

/// Keeps Liquid Glass call sites buildable on the app's iOS 18 deployment
/// target. iOS 26 uses the native effect; earlier systems receive a flat,
/// tinted surface that preserves contrast and shape.
extension View {
    @ViewBuilder
    func codegGlassEffect<S: Shape>(tint: Color? = nil, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background {
                ZStack {
                    shape.fill(Theme.bgElevated)

                    if let tint {
                        shape.fill(tint)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Uses native glass button styles on iOS 26 and the closest system button
    /// styles on iOS 18–25.
    @ViewBuilder
    func codegGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// On iOS 26 this groups neighboring glass shapes so they can blend together.
/// Earlier systems do not have an equivalent container, so content is rendered
/// unchanged.
struct CodegGlassEffectContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// A Liquid Glass surface for cards and rows, with a faint hairline for
/// definition on the dark backdrop.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.lg
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .codegGlassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hairlineBorder(cornerRadius)
    }
}

/// A flat grouped-list surface — like ``GlassCard`` but with a plain fill and no
/// Liquid Glass elevation, so the list sits flat on the backdrop with **no
/// floating shadow** (a frosted glass card reads as a shadowed plate on the light
/// near-white background). Used for the folder git tabs' Changes/Commits lists.
struct FlatCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.lg
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A compact accent capsule action button — the folder git tabs' Pull / Push /
/// Commit pills. `prominent` fills solid accent (the primary action); otherwise a
/// soft accent tint (the app's badge vocabulary). Deliberately flat (no glass, no
/// shadow) so it reads as a deliberate button, not a stray background plate, on
/// the light backdrop.
struct AccentPillButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.footnote.weight(.bold))
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(prominent ? Theme.onAccent : Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(prominent ? Theme.accent : Theme.accent.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(AccentPillButtonStyle())
    }
}

/// Press + disabled feedback for ``AccentPillButton``: a subtle scale/dim on press,
/// and a clear dim when disabled — a custom-styled button doesn't grey out on
/// `.disabled` the way the system styles do. Both this and its body view are
/// `private` (matching access) so the body can read `\.isEnabled`.
private struct AccentPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentPillButtonBody(configuration: configuration)
    }
}

private struct AccentPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// A tappable glass row used in lists (servers, sessions). Highlights with the
/// accent tint when `isSelected`.
struct GlassRow<Content: View>: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = Theme.Radius.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .codegGlassEffect(
                tint: isSelected ? Theme.accent.opacity(0.22) : nil,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .hairlineBorder(cornerRadius, color: isSelected ? Theme.accent.opacity(0.45) : Theme.surfaceStroke)
    }
}

/// A subtle press-feedback style for list / option rows: a slight scale-down and
/// dim on touch so a tap visibly registers (a `.plain` row gives no response at
/// all, which reads as "did that work?"). Shared so every tappable row across the
/// app responds identically. The scale is tiny (0.98) so it never clips in a List.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A small filter/selection chip.
struct FilterChip: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let isSelected: Bool
    /// Accent fill / on-accent text for the selected state. Default to the global
    /// `Theme.accent` tokens (driven by the bridged accent trait); callers that
    /// render where that trait can't reach — e.g. the Appearance preview, which
    /// also appears inside the iPad Settings *sheet* — pass an explicitly resolved
    /// color so the chip recolors regardless of presentation context.
    var tint: Color = Theme.accent
    var onTint: Color = Theme.onAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption2.weight(.semibold))
                }
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? onTint : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(isSelected ? tint : Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Compact: render `title` as a big, left-aligned bar item on the SAME row as
    /// the trailing toolbar buttons (inline mode, so there's no separate
    /// large-title band above it). Regular (iPad split): keep the standard system
    /// navigation title. Roots have no leading bar items, so the leading slot is
    /// free for the title.
    @ViewBuilder
    func screenTitle(_ title: LocalizedStringKey, compact: Bool) -> some View {
        if compact {
            // A large title that stays inline in the bar (doesn't collapse on
            // scroll), so it sits on the same row as the trailing buttons with no
            // separate large-title band above it.
            self
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inlineLarge)
        } else {
            self.navigationTitle(title)
        }
    }
}

/// Primary call-to-action, flat: a full-width solid-accent fill with no glass and
/// no shadow. The glass sibling ``PrimaryGlassButton`` renders as a washed-out
/// plate on the light near-white backdrop — and its disabled state nearly
/// vanishes — so sheets presented there (the commit composer) use this instead.
/// Disabled dims to a clearly-still-a-button 0.4, rather than disappearing.
struct FlatPrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isLoading: Bool = false
    var tint: Color = Theme.accent
    var onTint: Color = Theme.onAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(onTint)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.bold))
                }
                Text(title).fontWeight(.semibold)
            }
            .foregroundStyle(onTint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(FlatPrimaryButtonStyle())
        .disabled(isLoading)
    }
}

private struct FlatPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FlatPrimaryButtonBody(configuration: configuration)
    }
}

private struct FlatPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Primary call-to-action using prominent glass.
struct PrimaryGlassButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isLoading: Bool = false
    /// Prominent-glass tint / spinner color. Defaults to the global `Theme.accent`
    /// tokens; callers rendering outside the bridged accent trait's reach (the
    /// Appearance preview, which also shows inside the iPad Settings sheet) pass an
    /// explicitly resolved color so the button recolors there too.
    var tint: Color = Theme.accent
    var onTint: Color = Theme.onAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(onTint)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .codegGlassButtonStyle(prominent: true)
        .tint(tint)
        .disabled(isLoading)
    }
}
