import SwiftUI

/// App-wide backdrop: near-black with two soft color glows for depth.
/// Sits behind Liquid Glass surfaces so their translucency reads.
///
/// Each glow is a radial gradient shaped like the blurred disc it used to be
/// (a 0.95-width circle under a 130 / 150 pt Gaussian blur, centered where
/// that disc sat): the same light — a flattened render of the blurred discs
/// matches it to a level or two — without a full-screen blur pass. Every tab
/// and pushed screen has a backdrop, and a large live blur is filtered again
/// on each frame its page moves or fades, as it does on every tab switch and
/// push.
struct CodegBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    // The glows read boldly on near-black but turn muddy over a light backdrop,
    // so they're softened in light mode. The first glow follows the user accent.
    private var accentGlow: Double { colorScheme == .dark ? 0.16 : 0.10 }
    private var coolGlow: Double { colorScheme == .dark ? 0.14 : 0.07 }

    var body: some View {
        ZStack {
            Theme.bg
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Rectangle().fill(Self.glow(
                        Theme.accent, peak: accentGlow, profile: Self.sigma130,
                        center: UnitPoint(x: 0.195, y: 0.20), reach: w * 0.475 + 290))
                    Rectangle().fill(Self.glow(
                        Color(red: 0.30, green: 0.42, blue: 0.95), peak: coolGlow, profile: Self.sigma150,
                        center: UnitPoint(x: 0.835, y: 0.94), reach: w * 0.475 + 370))
                }
            }
        }
        .ignoresSafeArea()
    }

    /// A blurred disc's light by distance from its center, as a share of the
    /// gradient's reach: a disc of radius 191 pt under a Gaussian of 130 /
    /// 150 pt, sampled every 60 pt (out to 480 / 560 pt).
    private static let sigma130: [(Double, Double)] = [
        (0, 0.659), (0.125, 0.621), (0.25, 0.517), (0.375, 0.378), (0.5, 0.239),
        (0.625, 0.130), (0.75, 0.060), (0.875, 0.023), (1, 0),
    ]
    private static let sigma150: [(Double, Double)] = [
        (0, 0.554), (0.107, 0.526), (0.214, 0.449), (0.321, 0.344), (0.429, 0.235),
        (0.536, 0.143), (0.643, 0.076), (0.75, 0.036), (0.857, 0.015), (1, 0),
    ]

    private static func glow(_ color: Color, peak: Double, profile: [(Double, Double)],
                             center: UnitPoint, reach: CGFloat) -> RadialGradient {
        RadialGradient(
            gradient: Gradient(stops: profile.map { location, light in
                .init(color: color.opacity(peak * light), location: location)
            }),
            center: center, startRadius: 0, endRadius: reach)
    }
}

#Preview {
    CodegBackground()
}
