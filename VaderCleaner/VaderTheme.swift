// VaderTheme.swift
// VaderCleaner's visual identity: the space-black to Sith-red palette and the per-section gradient backdrop that hosts the app's Liquid Glass surfaces.

import SwiftUI

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
            .preferredColorScheme(.dark)
    }
}
