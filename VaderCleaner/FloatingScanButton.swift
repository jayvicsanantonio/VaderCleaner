// FloatingScanButton.swift
// The reusable hero call-to-action: a large circular accent-filled disc with a white ring, a breathing glow, and press feedback.

import SwiftUI

/// The hero / dashboard call to action — a circular button echoing the
/// reference's Scan disc. A saturated `accent` fill (crimson by default, so
/// unspecified call sites stay on the Vader palette) marks it as the primary
/// action, and a white ring lifts it off the backdrop. Shared across sections
/// so every "Scan"/"Clean" CTA stays visually identical.
///
/// The fill is a solid colour rather than a Liquid Glass material on purpose:
/// the floating Scan disc is hosted in a child panel that straddles the window
/// edge, so for its lower half there is no window backdrop for glass to tint
/// against — a glass disc reads as dark grey over the desktop.
struct FloatingScanButton: View {

    /// Diameter of the floating Scan disc. Shared as one constant so the disc,
    /// its host panel, and the panel's placement maths all agree on one size.
    static let floatingDiameter: CGFloat = 130

    let title: String
    var accent: Color = .vaderCrimson
    /// Diameter of the circular button. Defaults to the compact size used by
    /// in-window CTAs such as the Smart Scan "Clean" button; the floating Scan
    /// disc passes `floatingDiameter`.
    var diameter: CGFloat = 108
    let accessibilityIdentifier: String
    /// VoiceOver label. `nil` falls back to `title` so existing call sites
    /// keep announcing "Scan"; the scan-centric shell passes
    /// "Scan <Section>" so each section's disc is distinguishable.
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @State private var hovering = false
    @State private var pulsing = false

    /// The label VoiceOver will announce — the caller's override, or the
    /// visible title when none was supplied. Exposed so the contract is
    /// unit-testable without rendering.
    var resolvedAccessibilityLabel: String { accessibilityLabel ?? title }

    /// White ring width, scaled to the disc so it stays proportionate.
    private var borderWidth: CGFloat { max(1.5, diameter * 0.018) }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: diameter * 0.17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                // A flat, fully opaque accent fill — not a glass material and
                // not a fading gradient — so the disc reads as a solid section-
                // coloured button even where it floats over the desktop,
                // beyond any window backdrop glass could tint against.
                .background(
                    Circle().fill(accent)
                )
                // Crisp white ring, echoing the reference's lit disc.
                .overlay(
                    Circle().strokeBorder(.white, lineWidth: borderWidth)
                )
                // The frame is only transparent layout padding around the
                // text; without an explicit content shape the button's hit
                // region would collapse to the glyphs. Make the whole circle
                // the tappable surface.
                .contentShape(Circle())
        }
        .buttonStyle(PressableCircleButtonStyle())
        // Ambient accent glow that breathes so the primary action keeps drawing
        // the eye even when the rest of the screen is still.
        .shadow(
            color: accent.opacity(pulsing ? 0.65 : 0.4),
            radius: pulsing ? 30 : 18,
            y: 8
        )
        .scaleEffect(hovering ? 1.06 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: hovering)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulsing)
        .onHover { hovering = $0 }
        .onAppear { pulsing = true }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(resolvedAccessibilityLabel)
    }
}

/// Press feedback for the circular CTAs — a quick spring scale-down while
/// pressed so the button feels physical rather than flat.
private struct PressableCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}
