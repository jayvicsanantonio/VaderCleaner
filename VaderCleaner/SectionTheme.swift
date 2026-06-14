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
            // Keyed to the magenta-pink Smart Care hero asset.
            return SectionTheme(
                accent: Color(red: 0.90, green: 0.09, blue: 0.73),
                backdropTop: Color(red: 0.12, green: 0.03, blue: 0.10),
                backdropBottom: Color(red: 0.29, green: 0.06, blue: 0.24)
            )
        case .systemJunk:
            // Keyed to the green Cleanup disc asset.
            return SectionTheme(
                accent: Color(red: 0.13, green: 0.90, blue: 0.21),
                backdropTop: Color(red: 0.03, green: 0.12, blue: 0.04),
                backdropBottom: Color(red: 0.06, green: 0.29, blue: 0.08)
            )
        case .largeOldFiles:
            // Keyed to the teal My Clutter folder asset.
            return SectionTheme(
                accent: Color(red: 0.10, green: 0.90, blue: 0.86),
                backdropTop: Color(red: 0.03, green: 0.12, blue: 0.12),
                backdropBottom: Color(red: 0.06, green: 0.29, blue: 0.28)
            )
        case .spaceLens:
            // Keyed to the indigo-violet Space Lens asset.
            return SectionTheme(
                accent: Color(red: 0.38, green: 0.33, blue: 0.90),
                backdropTop: Color(red: 0.04, green: 0.03, blue: 0.12),
                backdropBottom: Color(red: 0.08, green: 0.06, blue: 0.29)
            )
        case .malwareRemoval:
            // Keyed to the magenta Protection octagon asset.
            return SectionTheme(
                accent: Color(red: 0.90, green: 0.18, blue: 0.76),
                backdropTop: Color(red: 0.12, green: 0.03, blue: 0.10),
                backdropBottom: Color(red: 0.29, green: 0.06, blue: 0.25)
            )
        case .optimization:
            // Keyed to the orange Performance bolt asset.
            return SectionTheme(
                accent: Color(red: 0.90, green: 0.33, blue: 0.16),
                backdropTop: Color(red: 0.12, green: 0.05, blue: 0.03),
                backdropBottom: Color(red: 0.29, green: 0.11, blue: 0.06)
            )
        case .privacy:
            // Keyed to the azure Cloud Storage asset.
            return SectionTheme(
                accent: Color(red: 0.14, green: 0.51, blue: 0.90),
                backdropTop: Color(red: 0.03, green: 0.08, blue: 0.12),
                backdropBottom: Color(red: 0.06, green: 0.17, blue: 0.29)
            )
        case .applications:
            // Keyed to the blue Applications hexagon asset, but a brighter,
            // less-saturated blue: the accent doubles as the control tint, so it
            // must read as legible icon and metric text on the dark backdrop —
            // the raw asset blue was too dark to see. The gradient is lifted off
            // near-black so the section no longer reads as a heavy navy.
            return SectionTheme(
                accent: Color(red: 0.30, green: 0.46, blue: 1.00),
                backdropTop: Color(red: 0.04, green: 0.06, blue: 0.17),
                backdropBottom: Color(red: 0.09, green: 0.13, blue: 0.37)
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
