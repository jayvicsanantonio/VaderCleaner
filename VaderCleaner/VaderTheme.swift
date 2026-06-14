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
/// section's hue, with a soft accent bloom centred low so the brightest part of
/// the glow pools behind the hero cluster and the floating Scan disc. Driven by
/// the section theme so navigating between sections recolours the whole window.
struct VaderBackground: View {
    /// The active section's colour identity. The whole backdrop is built from
    /// this, so the caller crossfades it as the selection changes.
    let theme: SectionTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backdropTop, theme.backdropBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [theme.accent.opacity(0.5), .clear],
                // y is biased well below centre so the bloom pools behind the
                // hero/title cluster and the floating Scan disc rather than the
                // empty middle of the window.
                center: UnitPoint(x: 0.5, y: 0.74),
                startRadius: 0,
                endRadius: 760
            )
        }
        .ignoresSafeArea()
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
    /// A foreground colour guaranteed to read on top of `self` when `self` is
    /// used as a fill: near-black on light fills, white on dark ones. Chosen by
    /// the fill's perceived luminance so accent-filled badges and buttons stay
    /// legible whether the section accent is a bright green or a deep blue.
    var legibleForeground: Color {
        Self.perceivedLuminance(of: self) > 0.45 ? Color(white: 0.08) : .white
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

/// Prominent action button that fills with the section accent and chooses a
/// legible label colour by the accent's luminance — so a bright green or cyan
/// section keeps readable (near-black) button text where the system's fixed
/// white label would wash out. Used for the section dashboards' and review
/// screens' primary actions; onboarding/permission flows keep the system style.
struct VaderProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentLabel(configuration: configuration)
    }

    private struct ProminentLabel: View {
        let configuration: Configuration
        @Environment(\.sectionAccent) private var accent
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        /// Large/extra-large controls get a taller capsule so the primary
        /// action bars keep the heft of a `.controlSize(.large)` button.
        private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

        var body: some View {
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: .semibold))
                .foregroundStyle(accent.legibleForeground)
                .padding(.horizontal, isLarge ? 20 : 14)
                .padding(.vertical, isLarge ? 9 : 6)
                .background(Capsule().fill(accent))
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.45)
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == VaderProminentButtonStyle {
    /// Section-accent prominent button with a luminance-aware label.
    static var vaderProminent: VaderProminentButtonStyle { VaderProminentButtonStyle() }
}
