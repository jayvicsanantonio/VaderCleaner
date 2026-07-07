// VaderTheme.swift
// VaderCleaner's visual identity: the space-black to Sith-red palette and the per-section gradient backdrop that hosts the app's Liquid Glass surfaces.

import SwiftUI
import AppKit

/// Palette for the Vader identity. Deep near-black base with a vivid crimson
/// accent — retained as the default control tint for surfaces that have no
/// section context (e.g. the Full Disk Access prompt card) and as the Smart
/// Scan section's hue.
extension Color {
    /// A near-black with a faint cool cast — the darkest base tone.
    static let vaderSpaceBlack = Color(red: 0.039, green: 0.039, blue: 0.055)
    /// A very dark crimson.
    static let vaderDeepRed = Color(red: 0.149, green: 0.027, blue: 0.055)
    /// Accent / tint — the lightsaber crimson used as the default control tint.
    static let vaderCrimson = Color(red: 0.851, green: 0.102, blue: 0.176)
}

/// Full-bleed branded backdrop: a vertical dark → rich gradient in the active
/// section's hue, under a cluster of accent blooms that orbit at different
/// radii, speeds, and directions with a slow brightness breathe — a lava-lamp
/// motion that keeps the gradient visibly alive. The blooms anchor along the
/// window edges so each shows only a partial arc — an atmospheric wash, not a
/// travelling circle — with the primary low on the bottom edge where its glow
/// still pools behind the floating Scan disc. Driven by the section theme so
/// navigating between sections recolours the whole window.
struct VaderBackground: View {
    /// The active section's colour identity. The whole backdrop is built from
    /// this, so the caller crossfades it as the selection changes.
    let theme: SectionTheme

    /// Flipped once on appear into a repeat-forever pulse that breathes the
    /// bloom cluster's brightness.
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backdropTop, theme.backdropBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { geo in
                ZStack {
                    // All three anchors hug (or overshoot) the window edges so
                    // only a partial arc of each glow is ever visible — the
                    // light reads as a wash coming in from the edge, never as
                    // a travelling circle.
                    //
                    // Primary bloom — the section's classic glow, low on the
                    // bottom edge where it still pools behind the floating
                    // Scan disc.
                    OrbitingBloom(
                        color: theme.accent.opacity(0.45),
                        falloff: 760,
                        anchor: UnitPoint(x: 0.5, y: 0.9),
                        orbitRadius: 160,
                        period: 20,
                        clockwise: true,
                        animated: !reduceMotion,
                        size: geo.size
                    )
                    // Secondary bloom — dimmer, wider orbit, counter-rotating
                    // just past the left edge so it swells in and out of the
                    // window as it circles.
                    OrbitingBloom(
                        color: theme.accent.opacity(0.26),
                        falloff: 460,
                        anchor: UnitPoint(x: -0.08, y: 0.3),
                        orbitRadius: 220,
                        period: 34,
                        clockwise: false,
                        animated: !reduceMotion,
                        size: geo.size
                    )
                    // Tertiary bloom — small and faint in the upper-right
                    // corner, on the fastest lap, adding a third phase.
                    OrbitingBloom(
                        color: theme.accent.opacity(0.2),
                        falloff: 320,
                        anchor: UnitPoint(x: 1.08, y: 0.08),
                        orbitRadius: 140,
                        period: 14,
                        clockwise: true,
                        animated: !reduceMotion,
                        size: geo.size
                    )
                }
                // A slow breathe over the whole cluster: brightness swells and
                // relaxes on a cycle offset from every orbit period, so the
                // combined motion never visibly repeats. Opacity is composited
                // on the GPU like the orbits — no per-frame view redraws.
                .opacity(breathing ? 0.86 : 1.0)
                .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: breathing)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // Honour Reduce Motion: the blooms stay put at their resting
            // poses at full brightness.
            guard !reduceMotion else { return }
            breathing = true
        }
    }
}

/// One accent bloom on a circular path: a radial glow displaced off the pivot
/// of an oversized square layer that spins forever — the orbit trick. The
/// gradient is radially symmetric, so the rotation itself is invisible; only
/// the circular travel shows. Rotation is a GPU-composited transform, no
/// per-frame view redraws.
private struct OrbitingBloom: View {
    /// The bloom's colour, opacity included.
    let color: Color
    /// Radius at which the glow fades to fully clear.
    let falloff: CGFloat
    /// Resting pose in window space — the top of the orbit, and where the
    /// bloom stays when the orbit is not animated (Reduce Motion).
    let anchor: UnitPoint
    /// Radius of the circular path.
    let orbitRadius: CGFloat
    /// Seconds per revolution.
    let period: Double
    /// Direction of travel around the circle.
    let clockwise: Bool
    /// Whether the orbit runs; false parks the bloom at its anchor.
    let animated: Bool
    /// The hosting window's size, from the caller's `GeometryReader`.
    let size: CGSize

    /// Flipped once on appear into the repeat-forever linear rotation that
    /// carries the bloom around its path.
    @State private var orbiting = false

    /// Side of the square layer the bloom is drawn on. Must contain the whole
    /// falloff plus the orbit displacement, so the layer's rectangular bounds
    /// always sit in the gradient's fully-clear region — a bounds cut inside
    /// the falloff shows up as a hard seam when the layer moves.
    private var layerSide: CGFloat { 2 * (falloff + orbitRadius) + 100 }

    var body: some View {
        RadialGradient(
            // A white-hot core inside the accent glow: on themes whose accent
            // sits close to the backdrop hue (Health Monitor's blue on blue),
            // a pure accent bloom moves almost invisibly — the bright core is
            // what keeps the motion legible on every section's palette.
            stops: [
                .init(color: .white.opacity(0.07), location: 0),
                .init(color: color, location: 0.3),
                .init(color: .clear, location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: falloff
        )
        .frame(width: layerSide, height: layerSide)
        .offset(y: -orbitRadius)
        .rotationEffect(.degrees(orbiting ? (clockwise ? 360 : -360) : 0))
        .animation(.linear(duration: period).repeatForever(autoreverses: false), value: orbiting)
        // The orbit's centre sits one radius below the anchor, so the
        // path's top — and the Reduce Motion resting pose — is exactly
        // the anchor.
        .position(
            x: size.width * anchor.x,
            y: size.height * anchor.y + orbitRadius
        )
        .onAppear {
            guard animated else { return }
            orbiting = true
        }
    }
}

extension View {
    /// Hosts a scene in the Vader shell: a forced dark appearance so system
    /// chrome and Liquid Glass adopt the light-on-dark vibrant treatment, and
    /// the supplied accent as the control tint. The per-section gradient
    /// backdrop is applied separately by `ContentView` so it can crossfade as
    /// the selection changes.
    func vaderShell(accent: Color) -> some View {
        self
            .tint(accent)
            // Mirror the accent into an environment value a `ButtonStyle` can
            // read — the tint shape style is not introspectable, but the
            // prominent button style needs the fill colour to pick a legible
            // label.
            .environment(\.sectionAccent, accent)
            .preferredColorScheme(.dark)
    }
}

extension Color {
    /// A deepened shade of `self` dark enough to carry white text or glyphs,
    /// returned only when `self` is too bright to do so as-is; otherwise `self`
    /// is returned unchanged. Lets accent-filled badges and buttons pair a
    /// single white foreground with the fill across every section — the bright
    /// green and cyan sections deepen their fill rather than flipping the label
    /// to black, while the already-deep accents stay exactly as they were.
    var deepenedForWhite: Color {
        guard Self.perceivedLuminance(of: self) > 0.45 else { return self }
        let base = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(white: 0.1, alpha: 1)
        // Scale the channels toward black until white clears a comfortable
        // contrast ratio — luminance ≤ 0.20 is roughly 4.4:1 against white.
        var scale: CGFloat = 1.0
        var candidate = base
        while scale > 0.05,
              Self.perceivedLuminance(of: Color(nsColor: candidate)) > 0.20 {
            scale -= 0.05
            candidate = NSColor(
                srgbRed: base.redComponent * scale,
                green: base.greenComponent * scale,
                blue: base.blueComponent * scale,
                alpha: 1
            )
        }
        return Color(nsColor: candidate)
    }

    /// WCAG relative luminance (0…1) of a colour in sRGB.
    fileprivate static func perceivedLuminance(of color: Color) -> Double {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(white: 0, alpha: 1)
        func channel(_ c: CGFloat) -> Double {
            let value = Double(c)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(resolved.redComponent)
            + 0.7152 * channel(resolved.greenComponent)
            + 0.0722 * channel(resolved.blueComponent)
    }
}

private struct SectionAccentKey: EnvironmentKey {
    static let defaultValue: Color = .vaderCrimson
}

extension EnvironmentValues {
    /// The active section's accent — the same colour as the control tint, but
    /// readable from a `ButtonStyle` (the tint shape style is not). Drives the
    /// prominent button fill and its legible label.
    var sectionAccent: Color {
        get { self[SectionAccentKey.self] }
        set { self[SectionAccentKey.self] = newValue }
    }
}

/// Prominent action button that fills with the section accent and labels it in
/// white, deepening the fill when the accent is too bright to carry white text —
/// so a bright green or cyan section reads as a deep, legible fill rather than
/// flipping to black text. Used for the section dashboards' and review screens'
/// primary actions; onboarding/permission flows keep the system style.
struct VaderProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentLabel(configuration: configuration)
    }

    private struct ProminentLabel: View {
        let configuration: Configuration
        @Environment(\.sectionAccent) private var accent
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// Large/extra-large controls get a taller capsule so the primary
        /// action bars keep the heft of a `.controlSize(.large)` button.
        private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

        var body: some View {
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, isLarge ? 20 : 14)
                .padding(.vertical, isLarge ? 9 : 6)
                .background(Capsule().fill(accent.deepenedForWhite))
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.45)
                .scaleEffect(VaderMotion.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
                .contentShape(Capsule())
                .animation(VaderMotion.control, value: configuration.isPressed)
                .recordsTriggerPress(isPressed: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == VaderProminentButtonStyle {
    /// Section-accent prominent button with a luminance-aware label.
    static var vaderProminent: VaderProminentButtonStyle { VaderProminentButtonStyle() }
}

extension Glass {
    /// The white-tinted glass shared by the dashboard tiles and the header
    /// pill buttons, lifting both a step brighter than the section backdrop
    /// (plain `.regular` glass darkens over the dark gradients).
    static var vaderTile: Glass { .regular.tint(.white.opacity(0.1)) }
}

/// Neutral Liquid Glass capsule with a white semibold label — the Review
/// treatment on the dashboard tiles. Hand-rolled over `glassEffect` rather
/// than `.buttonStyle(.glass)` because the system style fills with the
/// window's control tint (the section accent), while the reference keeps
/// these capsules free of it. On-tile capsules use the darker plain glass;
/// `matchesTileSurface` swaps in the tiles' white-tinted shade for the
/// dashboards' header pills.
struct VaderGlassButtonStyle: ButtonStyle {
    var matchesTileSurface = false

    func makeBody(configuration: Configuration) -> some View {
        GlassLabel(configuration: configuration, matchesTileSurface: matchesTileSurface)
    }

    private struct GlassLabel: View {
        let configuration: Configuration
        let matchesTileSurface: Bool
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// Large/extra-large controls get the header pills' roomier capsule;
        /// the default size stays compact enough for two capsules to share a
        /// narrow two-up tile.
        private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

        var body: some View {
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white)
                // A capsule label must never wrap mid-word on a narrow tile.
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, isLarge ? 20 : 14)
                .padding(.vertical, isLarge ? 9 : 6)
                .glassEffect(
                    matchesTileSurface ? Glass.vaderTile.interactive() : Glass.regular.interactive(),
                    in: .capsule
                )
                .opacity(configuration.isPressed ? 0.82 : 1.0)
                .scaleEffect(VaderMotion.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
                .contentShape(Capsule())
                .animation(VaderMotion.control, value: configuration.isPressed)
                .recordsTriggerPress(isPressed: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == VaderGlassButtonStyle {
    /// Tint-free glass capsule for the dashboards' Review-style actions.
    static var vaderGlass: VaderGlassButtonStyle { VaderGlassButtonStyle() }
    /// Glass capsule in the tiles' white-tinted shade — the dashboards'
    /// "Review All / View All / Manage" header pills.
    static var vaderTileGlass: VaderGlassButtonStyle { VaderGlassButtonStyle(matchesTileSurface: true) }
}

/// Solid white capsule with a black semibold label — the dashboards' direct
/// Clean/Remove treatment, reading as the brightest element on the glass
/// tiles. Metrics mirror the glass capsule beside it so the pair sits on one
/// baseline at one height.
struct VaderWhiteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WhiteLabel(configuration: configuration)
    }

    private struct WhiteLabel: View {
        let configuration: Configuration
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

        var body: some View {
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: .semibold))
                .foregroundStyle(.black)
                // A capsule label must never wrap mid-word on a narrow tile.
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, isLarge ? 20 : 14)
                .padding(.vertical, isLarge ? 9 : 6)
                .background(Capsule().fill(.white))
                .opacity(configuration.isPressed ? 0.82 : 1.0)
                .scaleEffect(VaderMotion.pressScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
                .contentShape(Capsule())
                .animation(VaderMotion.control, value: configuration.isPressed)
                .recordsTriggerPress(isPressed: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == VaderWhiteButtonStyle {
    /// White-filled capsule for the dashboard tiles' direct primary action.
    static var vaderWhite: VaderWhiteButtonStyle { VaderWhiteButtonStyle() }
}

extension View {
    /// The dashboard tile surface shared by every section's grid screen:
    /// Liquid Glass under the reference's large corner radius, in the shared
    /// white-tinted shade (`Glass.vaderTile`).
    func vaderTileGlass() -> some View {
        glassEffect(.vaderTile, in: .rect(cornerRadius: 24))
    }
}
