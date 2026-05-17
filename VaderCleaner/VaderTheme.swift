// VaderTheme.swift
// VaderCleaner's branded visual identity: the space-black to Sith-red palette, the gradient backdrop, and the app-wide shell modifier that hosts Liquid Glass surfaces.

import SwiftUI

/// Palette for the Vader identity. Deep near-black base with a vivid crimson
/// accent — chosen so translucent Liquid Glass surfaces layered on top pick up
/// a warm refraction without washing out white foreground text.
extension Color {
    /// Top of the window gradient — near-black with a faint cool cast.
    static let vaderSpaceBlack = Color(red: 0.039, green: 0.039, blue: 0.055)
    /// Bottom of the window gradient — a very dark crimson so the base reads
    /// "Vader" rather than a neutral dark theme.
    static let vaderDeepRed = Color(red: 0.149, green: 0.027, blue: 0.055)
    /// Accent / tint — the lightsaber crimson used for the primary call to
    /// action, the sidebar selection, and control tinting.
    static let vaderCrimson = Color(red: 0.851, green: 0.102, blue: 0.176)
}

/// Full-bleed branded backdrop: a vertical space-black → deep-crimson gradient
/// with a soft crimson bloom centred slightly below the window's middle, so the
/// hero content sits in the brightest part of the glow like the reference.
struct VaderBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.vaderSpaceBlack, .vaderDeepRed],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.vaderCrimson.opacity(0.34), .clear],
                // y is biased just below the vertical centre (rather than 0.5)
                // so the brightest part of the bloom falls under the hero
                // icon/title cluster on the welcome screen, not the empty
                // middle of the window.
                center: UnitPoint(x: 0.5, y: 0.58),
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Hosts a scene in the Vader shell: the gradient backdrop behind
    /// everything, a forced dark appearance so system chrome and Liquid Glass
    /// adopt the light-on-dark vibrant treatment, and the crimson accent tint.
    ///
    /// Applied at the `NavigationSplitView` root. List and scroll backgrounds
    /// are cleared per-view so the gradient shows through the sidebar and
    /// detail panes while their glass surfaces float on top.
    func vaderShell() -> some View {
        self
            .background(VaderBackground())
            .tint(Color.vaderCrimson)
            .preferredColorScheme(.dark)
    }
}
