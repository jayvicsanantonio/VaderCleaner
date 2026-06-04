// SectionTheme.swift
// Per-section color identity — the accent and backdrop gradient that retint the whole window as the user moves between sections.

import SwiftUI

/// The color identity for one navigation section. `accent` is the vivid hue
/// shared by the hero glow, the feature badges, the floating Scan disc, and the
/// section's sidebar icon. `backdropTop`/`backdropBottom` are the dark base of
/// the window gradient; the accent also blooms up through it as a radial glow.
struct SectionTheme: Equatable {
    /// The vivid section hue — hero glow, feature badges, Scan disc, rail icon.
    let accent: Color
    /// Top of the window gradient: the darkest corner tone.
    let backdropTop: Color
    /// Bottom of the window gradient: a deeper, more saturated base that the
    /// accent bloom sits over.
    let backdropBottom: Color
}

extension NavigationSection {
    /// This section's color identity. Defined for every case — the window
    /// backdrop is keyed to the section, so the non-scannable management
    /// screens need a theme too. Exhaustive switch with no `default` so a new
    /// section is a compile-time prompt to give it a hue.
    var theme: SectionTheme {
        switch self {
        case .smartScan:
            // The brand-crimson hero section — the app's Vader identity.
            return SectionTheme(
                accent: .vaderCrimson,
                backdropTop: Color(red: 0.12, green: 0.02, blue: 0.04),
                backdropBottom: Color(red: 0.30, green: 0.05, blue: 0.10)
            )
        case .systemJunk:
            return SectionTheme(
                accent: Color(red: 0.36, green: 0.83, blue: 0.42),
                backdropTop: Color(red: 0.04, green: 0.11, blue: 0.06),
                backdropBottom: Color(red: 0.07, green: 0.28, blue: 0.13)
            )
        case .largeOldFiles:
            return SectionTheme(
                accent: Color(red: 0.24, green: 0.81, blue: 0.74),
                backdropTop: Color(red: 0.03, green: 0.11, blue: 0.11),
                backdropBottom: Color(red: 0.05, green: 0.26, blue: 0.26)
            )
        case .spaceLens:
            return SectionTheme(
                accent: Color(red: 0.46, green: 0.44, blue: 0.99),
                backdropTop: Color(red: 0.06, green: 0.06, blue: 0.18),
                backdropBottom: Color(red: 0.13, green: 0.13, blue: 0.40)
            )
        case .malwareRemoval:
            return SectionTheme(
                accent: Color(red: 0.92, green: 0.22, blue: 0.32),
                backdropTop: Color(red: 0.13, green: 0.03, blue: 0.05),
                backdropBottom: Color(red: 0.34, green: 0.05, blue: 0.11)
            )
        case .optimization:
            return SectionTheme(
                accent: Color(red: 0.98, green: 0.60, blue: 0.20),
                backdropTop: Color(red: 0.13, green: 0.07, blue: 0.02),
                backdropBottom: Color(red: 0.34, green: 0.17, blue: 0.04)
            )
        case .privacy:
            return SectionTheme(
                accent: Color(red: 0.96, green: 0.30, blue: 0.64),
                backdropTop: Color(red: 0.13, green: 0.04, blue: 0.09),
                backdropBottom: Color(red: 0.33, green: 0.08, blue: 0.21)
            )
        case .applications:
            return SectionTheme(
                accent: Color(red: 0.52, green: 0.50, blue: 0.95),
                backdropTop: Color(red: 0.07, green: 0.06, blue: 0.16),
                backdropBottom: Color(red: 0.16, green: 0.14, blue: 0.37)
            )
        case .healthMonitor:
            return SectionTheme(
                accent: Color(red: 0.30, green: 0.86, blue: 0.64),
                backdropTop: Color(red: 0.03, green: 0.11, blue: 0.09),
                backdropBottom: Color(red: 0.06, green: 0.27, blue: 0.20)
            )
        }
    }
}
